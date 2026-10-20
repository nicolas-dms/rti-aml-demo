# Azure DevOps - mise en place (piste C, niveau 2)

Facultatif. Sans Azure DevOps, la piste C se joue avec les scripts (voir `docs/QUICKSTART.md`, niveau 1).
Ce guide crée ce que les pipelines `rti-train` et `rti-publish` attendent. Aucun secret nulle part :
les connexions de service utilisent la **fédération d'identité (workload identity federation)**.

Les valeurs entre chevrons viennent de `demo.config.env`. Les noms ci-dessous sans chevrons sont des
**conventions écrites dans les YAML** (`devops/`) : si vous les changez, changez-les aussi dans les YAML.

| Élément | Nom | Où il est utilisé |
|---|---|---|
| Organisation / projet | `<ADO_ORGANIZATION>` / `<ADO_PROJECT>` | à créer ; le dépôt Git du projet reçoit ce code |
| Pool d'agents | `rti-mlops-local` (auto-hébergé) | `pool:` des trois pipelines |
| Connexion DEV | `sc-rti-aml-dev` | `train.yml`, début de `publish.yml` (partage vers le registre) |
| Connexion PROD | `sc-rti-aml-prod` | `publish.yml` (déploiement PROD) |
| Environnement | `rti-prod`, avec approbation | `publish.yml`, étape de candidat |
| Pipelines | `rti-train`, `rti-publish`, `rti-auth-test` | fichiers `devops/pipelines/*.yml` |

## 1. Projet et dépôt

1. https://dev.azure.com : créer (ou choisir) l'organisation `<ADO_ORGANIZATION>`, puis un projet `<ADO_PROJECT>` (privé).
2. Repos > importer ou pousser ce dépôt sur la branche `main`.
3. Reporter l'organisation et le projet dans `demo.config.env` (`ADO_ORGANIZATION`, `ADO_PROJECT`).

## 2. Agent auto-hébergé

Les pipelines tournent sur un agent que vous hébergez (Windows de préférence, avec PowerShell) : le poste doit être allumé pendant les runs.
Sur l'agent : `az` CLI avec l'extension `ml` à la version épinglée dans `devops/templates/setup-azml.yml`, `python` 3.10+, `git`.

1. Organization settings > Agent pools > Add pool > Self-hosted, nom `rti-mlops-local`.
2. New agent : suivre les instructions affichées (télécharger, `config`, lancer en service ou en `run`).
3. Vérifier que l'agent est **Online**.

## 3. Deux connexions de service (fédération d'identité)

Project settings > Service connections > New service connection > **Azure Resource Manager** >
**Workload identity federation (automatic)** > Scope level **Subscription** > votre abonnement.
Laisser le champ Resource group **vide** (les rôles sont donnés plus finement ci-dessous).

| Nom | Application créée (exemple) |
|---|---|
| `sc-rti-aml-dev` | `rti-aml-dev-ado` |
| `sc-rti-aml-prod` | `rti-aml-prod-ado` |

Cochez **Grant access permission to all pipelines** si vous ne voulez pas autoriser chaque pipeline au premier run.

Récupérer l'Object ID de chaque principal de service : portail Entra > Applications d'entreprise > (retirer le filtre
Microsoft) > chercher le nom de l'application > **Object ID**. Les reporter dans `demo.config.env` :
`SP_DEV_OBJECT_ID` et `SP_PROD_OBJECT_ID`.

## 4. Rôles Azure des deux principaux de service

Principe : DEV écrit dans DEV et dans le registre ; PROD lit le registre et n'écrit que dans PROD.
Le registre est traité par un script, le reste est à faire une fois :

```powershell
# registre : DEV = AzureML Registry User, PROD = Reader
.\scripts\71_mlops_rbac.ps1
.\scripts\71_mlops_rbac.ps1 -VerifyOnly
```

```powershell
# Lire la configuration une fois
$cfg  = '.\scripts\lib\cfg.ps1'
$sub  = & $cfg AZURE_SUBSCRIPTION_ID -Required
$rg   = & $cfg AZURE_RESOURCE_GROUP  -Required
$dev  = & $cfg AML_DEV_WORKSPACE     -Required
$prod = & $cfg AML_PROD_WORKSPACE    -Required
$sa   = & $cfg STORAGE_ACCOUNT       -Required
$spDev  = & $cfg SP_DEV_OBJECT_ID    -Required
$spProd = & $cfg SP_PROD_OBJECT_ID   -Required
$base = "/subscriptions/$sub/resourceGroups/$rg/providers"

# DEV : travaille dans le workspace DEV et lit les snapshots dans ADLS
az role assignment create --assignee-object-id $spDev --assignee-principal-type ServicePrincipal `
  --role "AzureML Data Scientist" --scope "$base/Microsoft.MachineLearningServices/workspaces/$dev"
az role assignment create --assignee-object-id $spDev --assignee-principal-type ServicePrincipal `
  --role "Storage Blob Data Reader" --scope "$base/Microsoft.Storage/storageAccounts/$sa"

# PROD : travaille dans le workspace PROD uniquement
az role assignment create --assignee-object-id $spProd --assignee-principal-type ServicePrincipal `
  --role "AzureML Data Scientist" --scope "$base/Microsoft.MachineLearningServices/workspaces/$prod"
```

Le workspace PROD est créé par `scripts/70_mlops_prod_bootstrap.ps1` : faites ce bloc après lui.
Si un rôle est déjà présent, `az` le dit sans rien casser.

## 5. Environnement `rti-prod`

Pipelines > Environments > New environment, nom `rti-prod`, ressource None. Puis menu `...` > **Approvals and checks** >
Approvals > ajouter vous-même (ou un relecteur). `publish.yml` s'arrête là avant de toucher PROD.

## 6. Créer un pipeline depuis le YAML

Prérequis : le fichier est poussé sur `main`.

1. Pipelines > New pipeline > Azure Repos Git > votre dépôt > Existing Azure Pipelines YAML file.
2. Branche `main`, chemin du fichier (tableau), Continue, puis Save (pas Run).
3. Renommer le pipeline (menu `...` > Rename/move).
4. Premier Run : Azure DevOps demande d'autoriser la connexion de service et le pool pour **ce pipeline** : Permit.

| Nom du pipeline | Fichier | Rôle |
|---|---|---|
| `rti-auth-test` | `devops/pipelines/auth-test.yml` | vérifie les deux identités et leur isolation (lecture seule) |
| `rti-train` | `devops/pipelines/train.yml` | M3 : enregistre l'asset gelé, entraîne, valide, enregistre le modèle |
| `rti-publish` | `devops/pipelines/publish.yml` | M6 : partage au registre, déploie en PROD par étapes |

Lancer d'abord `rti-auth-test` : s'il est vert, les connexions et les rôles sont bons.

## Lancer `rti-train`

Run pipeline, paramètre `snapshotId` obligatoire : la valeur seule, ex. `20261013-1315` (pas `snapshotId=...`).
Prérequis : le dossier du snapshot existe dans ADLS (notebook `04`) et `sc-rti-aml-dev` a le rôle Storage Blob Data
Reader sur le compte ADLS. Le pipeline enregistre lui-même l'asset `telemetry_train:<snapshotId>` s'il n'existe pas
(`scripts/72_register_snapshot_asset.py`, sans écrasement), à partir d'un environnement Python créé une fois sur l'agent
(`devops/requirements-ci.txt`).
Le paramètre `maxMae` vaut 5.0 ; `0.1` fait échouer la gate à dessein.

Résultat attendu : job AML `Completed`, nouvelle version de `temp_forecaster` taguée (`git_sha`, `ado_build_id`,
`data_asset`, `data_manifest_sha256`), artefact `model-info` publié.

## Pièges connus

- Un run ne démarre pas tant que l'agent n'est pas en ligne : Project settings > Agent pools > `rti-mlops-local`.
- La permission d'une connexion de service est **par pipeline** : un nouveau pipeline redemande l'autorisation.
- L'extension `ml` doit rester à la version épinglée dans `devops/templates/setup-azml.yml`.
- Les pipelines lisent `demo.config.env` **dans le dépôt poussé** : poussez la config à jour avant un run.
- Une politique d'entreprise peut interdire la création de l'application derrière une connexion de service : demandez à un administrateur de la créer.

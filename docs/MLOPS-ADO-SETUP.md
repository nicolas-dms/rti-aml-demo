# Azure DevOps - mise en place (piste C)

Ce qui a été fait à la main dans le portail, et comment créer les pipelines à partir du YAML.
Aucun secret nulle part : les connexions de service utilisent la fédération d'identité.

## Éléments en place

| Élément | Valeur |
|---|---|
| Organisation / projet / dépôt | `<ADO_ORG>` / `rti-aml-demo` / `rti-aml-demo` (Azure Repos, branche `main`) |
| Pool et agent | `rti-mlops-local`, agent auto-hébergé `rti-mlops-arm64` (le poste doit être allumé) |
| Connexion DEV | `sc-rti-aml-dev` (application `rti-aml-dev-ado`) : AzureML Data Scientist sur `aml-rti-demo`, AzureML Registry User sur `mlr-rti-demo` |
| Connexion PROD | `sc-rti-aml-prod` (application `rti-aml-prod-ado`) : AzureML Data Scientist sur `aml-rti-prod`, Reader sur `mlr-rti-demo` |
| Environnement | `rti-prod` avec approbation (utilisé par `rti-publish`) |
| Test d'identité | pipeline `rti-auth-test` (`devops/pipelines/auth-test.yml`) |

## Créer un pipeline depuis le YAML

Prérequis : le fichier est poussé sur `main` d'Azure Repos.

1. Pipelines > New pipeline > Azure Repos Git > `rti-aml-demo` > Existing Azure Pipelines YAML file.
2. Branche `main`, chemin du fichier (tableau ci-dessous), Continue, puis Save (pas Run).
3. Renommer le pipeline (menu ... > Rename/move).
4. Premier Run : Azure DevOps demande d'autoriser la connexion de service (et le pool) pour **ce pipeline** : Permit.

| Nom du pipeline | Fichier |
|---|---|
| `rti-train` | `devops/pipelines/train.yml` |
| `rti-publish` | `devops/pipelines/publish.yml` (M6) |

## Lancer `rti-train`

Run pipeline, paramètre `snapshotId` obligatoire : la valeur seule, ex. `20261013-1315` (pas `snapshotId=...`).
Prérequis : le dossier du snapshot existe dans ADLS (notebook `04`) et `sc-rti-aml-dev` a le rôle Storage Blob Data
Reader sur `<STORAGE_ACCOUNT>`. Le pipeline enregistre lui-même l'asset `telemetry_train:<snapshotId>` s'il n'existe pas
(`scripts/72_register_snapshot_asset.py`, sans écrasement), à partir d'un environnement Python créé une fois sur l'agent
(`devops/requirements-ci.txt`).
Le paramètre `maxMae` vaut 5.0 ; `0.1` fait échouer la gate à dessein.

Résultat attendu : job AML `Completed`, nouvelle version de `temp_forecaster` taguée (`git_sha`, `ado_build_id`,
`data_asset`, `data_manifest_sha256`), artefact `model-info` publié.

## Pièges connus

- Un run ne démarre pas tant que l'agent n'est pas en ligne : Project settings > Agent pools > `rti-mlops-local`.
- La permission d'une connexion de service est **par pipeline** : un nouveau pipeline redemande l'autorisation.
- L'extension `ml` doit rester à la version épinglée dans `devops/templates/setup-azml.yml`.

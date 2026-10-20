# Démarrage rapide - installer la démo dans votre environnement

Ce guide mène de zéro (un abonnement Azure et une capacité Fabric) à une démo qui tourne : télémétrie temps réel
dans Fabric, modèle entraîné dans Azure ML, endpoint, Function de scoring, puis (niveau 2) la chaîne MLOps
DEV -> PROD. Deux façons de le suivre :

- **Chemin A, manuel** : vous lancez les scripts dans l'ordre indiqué ci-dessous.
- **Chemin B, assisté** : l'agent `RTI-AML-Agent` de VS Code déroule ce même guide avec vous (section 4).

Un seul fichier de paramètres : **`demo.config.env`** (racine du dépôt). Aucun secret dedans.

## 0. Ce que vous obtenez, et ce que cela coûte

| Niveau | Contenu | Prérequis en plus |
|---|---|---|
| **1 - Boucle temps réel** (piste A) | Eventhouse + Eventstream, snapshot, entraînement AML, endpoint, Function qui écrit les prédictions dans l'Eventhouse, tableau de bord | - |
| **2 - MLOps DEV -> PROD** (piste C) | données figées et versionnées, registre partagé, workspace PROD, publication progressive (mirror, canary, promote) | **Azure DevOps** pour les pipelines ; sans lui, les mêmes étapes se lancent à la main (scripts 20 et 80) |

Ce qui facture, par ordre d'importance : la **capacité Fabric** tant qu'elle est active (de loin), les **endpoints
managés** (24 h / 24 tant qu'ils existent, deux instances pendant une publication), le **registre AML** (stockage +
ACR). Le cluster d'entraînement et la Function ne coûtent presque rien au repos. Voir la section 7 pour tout arrêter.

## 1. Prérequis

Sur le poste (Windows, PowerShell 5.1 ou plus récent) :

| Outil | Version | Vérification |
|---|---|---|
| Azure CLI | récente | `az version` |
| Extension `ml` | **2.44.1** (celle validée) | `az extension add -n ml --version 2.44.1 --upgrade` |
| Python | 3.10 ou plus | `python --version` |
| Azure Functions Core Tools | 4.x (pour déployer la Function) | `func --version` |
| Git | - | `git --version` |

Dans Azure et Fabric :

- un **abonnement** où vous pouvez créer des ressources et attribuer des rôles (Owner, ou Contributor + User Access Administrator) ;
- une **capacité Fabric** existante (F2 ou plus, ou un essai Fabric), dans la **même région** que vos ressources Azure.
  Les scripts ne la créent pas ;
- Fabric activé pour votre tenant, et le droit de créer un workspace sur cette capacité.

Dans chaque nouveau terminal, depuis la racine du dépôt :

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force   # sinon: "running scripts is disabled"
az login --tenant <votre-tenant-id>
```

> Si le terminal intégré de VS Code ne trouve pas `az`, ajoutez
> `$env:PATH = "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin;$env:PATH"`.
> Les scripts sont en ASCII et compatibles Windows PowerShell 5.1.

## 2. Renseigner `demo.config.env`

```powershell
.\scripts\00a_init_config.ps1        # pré-remplit abonnement, tenant, capacité Fabric, région, nom du registre
```

Puis ouvrez `demo.config.env` et complétez ce qui reste (le script liste les clés manquantes). Les clés **obligatoires** :

| Clé | Exemple | Remarque |
|---|---|---|
| `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID` | - | `az account show` |
| `AZURE_LOCATION` | `westus3` | même région que la capacité Fabric |
| `AZURE_RESOURCE_GROUP` | `rg-rti-aml-demo` | un seul groupe pour tout |
| `AML_DEV_WORKSPACE`, `AML_PROD_WORKSPACE` | `aml-rti-demo`, `aml-rti-prod` | le PROD n'est utile qu'au niveau 2 |
| `AML_REGISTRY` | `mlr-rti-<suffixe>` | **unique dans le tenant** (le script ajoute un suffixe) |
| `FABRIC_CAPACITY`, `FABRIC_CAPACITY_RESOURCE_GROUP` | - | capacité existante |
| `FABRIC_WORKSPACE` | `ws-rti-aml-demo` | créé par le script 10 |

Les comptes de stockage et la Function (`STORAGE_ACCOUNT`, `FUNCTION_STORAGE_ACCOUNT`, `FUNCTION_APP`) peuvent rester vides :
`00_bootstrap.ps1` les calcule (noms uniques dérivés de l'abonnement et du groupe) et **les écrit dans le fichier**.
De même, `10_fabric_rti.ps1` écrit les identifiants Fabric (section 6 du fichier). Les clés `ADO_*` et `SP_*` ne servent
qu'au niveau 2 avec Azure DevOps.

Règle de lecture, utile pour déboguer : variable d'environnement `RTI_<CLE>`, sinon le fichier, sinon la valeur par défaut.
Une valeur vide ou entre chevrons `<...>` compte comme non renseignée.

Vérifier avant de continuer (lecture seule : ne crée rien) :

```powershell
.\scripts\00b_preflight.ps1
```

Il contrôle les outils, la session `az` (bon tenant), les clés, les fournisseurs de ressources, vos droits, la capacité Fabric
(existe, `Active`) et la disponibilité des noms de stockage. **Aucun FAIL** avant de continuer.
Une capacité `Paused` est signalée : reprenez-la (`az fabric capacity resume --resource-group <rg-capacité> --capacity-name <capacité>`)
puis attendez l'état `Active` (voir [RUNBOOK.md](RUNBOOK.md), étape 1).

## 3. Chemin A - pas à pas

Chaque étape est idempotente : on peut la relancer. Après chacune, une **vérification** ; ne passez pas à la suivante sans elle.

### Niveau 1 - la boucle temps réel

**1. Ressources Azure de base** - groupe de ressources, ADLS Gen2, workspace AML DEV, cluster `cpu-cluster` (min 0), datastore, Function App.

```powershell
.\scripts\00_bootstrap.ps1
```
Vérif. : le script se termine sans erreur et `demo.config.env` contient `STORAGE_ACCOUNT`, `FUNCTION_STORAGE_ACCOUNT`, `FUNCTION_APP`.

**2. Identité du cluster AML** - donne au cluster une identité et lui ouvre le stockage des snapshots.

```powershell
.\scripts\23_aml_compute_identity.ps1
```
Si votre workspace AML existait déjà avec des clés d'accès (stratégie interdisant les clés partagées), lancez d'abord
`.\scripts\22_aml_identity_datastores.ps1`. Sur un workspace créé par `00_bootstrap.ps1`, ce n'est pas nécessaire.

**3. Couche Fabric** - workspace, Eventhouse `eh-sensors`, base KQL `sensors`. Écrit les identifiants et URI dans `demo.config.env`.

```powershell
.\scripts\10_fabric_rti.ps1
```
Vérif. : `FABRIC_WORKSPACE_ID`, `KQL_DATABASE_ID`, `KUSTO_QUERY_URI` sont renseignés.

**4. Tables et fonctions KQL** - table `telemetry`, mirroring OneLake, table `scoring_results`, fonction `features_now()`.

```powershell
foreach ($f in '01_create_tables','02_onelake_availability','03_scoring_table','04_feature_function') {
    .\scripts\11_apply_kql.ps1 -Files "fabric\kql\$f.kql"
}
```
Vérif. : chaque fichier affiche `OK`. (Le fichier `05_function_permissions.generated.kql` est produit plus tard par le script 32.)

**5. Eventstream** - crée `es-sensors` et écrit la chaîne de connexion du point d'entrée dans `.env` (ignoré par git, jamais affichée).

```powershell
.\scripts\12_fabric_eventstream.ps1
```
Vérif. : `.env` contient `EVENTSTREAM_CONNECTION_STRING`. Dans le portail Fabric, la destination de l'Eventstream est `Running`.
Si elle est restée `Paused` : `.\scripts\15_eventstream_resume.ps1`.

**6. Simulateur** - **seulement une fois la destination `Running`** : les événements envoyés avant sont perdus.

```powershell
python -m venv .venv ; .\.venv\Scripts\Activate.ps1
pip install -r simulator\requirements.txt
python simulator\sensor_producer.py --backfill-minutes 1440
```
Laissez-le tourner (4 appareils, 1 message par seconde). Le backfill donne l'historique dont la fonction de variables a besoin.
Vérif. (requête dans l'Eventhouse) : `telemetry | summarize count(), min(timestamp), max(timestamp)` puis `features_now() | count` = **4**.

**7. Notebooks** - publie `01` et `04` dans le workspace Fabric. Les constantes d'en-tête sont remplacées à l'envoi par vos valeurs.

```powershell
.\scripts\14_fabric_notebook.ps1
```

**8. Premier snapshot d'entraînement** - dans le portail Fabric, ouvrez le notebook `01_snapshot_to_datastore` et faites **Run all**.
Attendre au moins 10 minutes après le début de l'ingestion (le mirroring OneLake n'est pas immédiat).
Il écrit les données dans le datastore AML (`telemetry/v1`) puis affiche la commande suivante :

```powershell
az ml data create -f aml/data/data-asset.yml -g <AZURE_RESOURCE_GROUP> -w <AML_DEV_WORKSPACE>
```
Vérif. : `az ml data show -n telemetry_features -v 1 -g <rg> -w <workspace>` renvoie l'asset.

**9. Entraînement AML** - environnement, pipeline `prep -> train -> evaluate -> register`. Compter 10 à 20 minutes (premier build d'image).

```powershell
.\scripts\20_aml_train.ps1
```
Vérif. : job `Completed`, modèle `temp_forecaster` version 1 enregistré. En cas d'échec : `.\scripts\21_aml_job_logs.ps1 -JobName <nom>`.

**10. Endpoint managé** - crée `temp-forecast-ep` et le déploiement `blue` (8 à 15 minutes), puis un appel de test.

```powershell
.\scripts\30_aml_endpoint.ps1 -ModelVersion 1
```
Vérif. : l'appel de test renvoie une prédiction. **L'endpoint facture 24 h / 24 à partir d'ici.**

**11. Function de scoring** - droits (identités managées, pas de clés) puis publication.

```powershell
.\scripts\32_function_config.ps1
.\scripts\33_function_deploy.ps1
.\scripts\35_invoke_score_once.ps1      # force une exécution tout de suite
```
Vérif. (Eventhouse) : `scoring_results | top 5 by scored_at desc` contient des lignes avec `deployment = blue`.

**12. Tableau de bord** - Real-Time Dashboard à partir de `fabric/dashboard/`.

```powershell
.\scripts\40_fabric_dashboard.ps1
```

**Niveau 1 terminé** : la télémétrie arrive, le modèle prédit, les prédictions reviennent dans l'Eventhouse.
Pour la démonstration blue/green de la piste A (`41_aml_traffic.ps1`), voir [DEMO-PLAN.md](DEMO-PLAN.md) (P7).

### Niveau 2 - MLOps DEV -> PROD

Concepts et déroulé d'un cycle : [MLOPS-GUIDE.md](MLOPS-GUIDE.md). Ici, la mise en place.

**13. Workspace PROD et registre partagé**

```powershell
.\scripts\70_mlops_prod_bootstrap.ps1
.\scripts\75_mlops_registry.ps1
```
Le registre a un coût permanent (stockage + ACR). Si votre tenant impose des politiques (réseau public interdit), le registre
peut exiger une exemption : le script le signale. Plan B documenté : copie tracée du modèle (`model download` + `model create`).

**14. Snapshot figé et versionné** - notebook `04_snapshot_versioned` (Run all). Il écrit `data.parquet` puis `_manifest.json`
(en dernier : sa présence prouve que le snapshot est complet) et affiche l'identifiant, par exemple `20261014-1315`.

**15. Entraîner sur ce snapshot** - deux voies :

- *Sans Azure DevOps* : enregistrer l'asset puis lancer l'entraînement avec l'identifiant.
  ```powershell
  pip install -r devops\requirements-ci.txt                              # une fois, dans le venv
  python scripts\72_register_snapshot_asset.py --snapshot-id 20261014-1315
  .\scripts\20_aml_train.ps1 -SnapshotId 20261014-1315
  ```
  `prep` vérifie les empreintes du manifest et des données **avant** tout entraînement.
- *Avec Azure DevOps* : pipeline `rti-train` (section suivante).

**16. Endpoint PROD, première couleur** - une seule fois, la veille de la démo (il facture 24 h / 24).

```powershell
.\scripts\81_prod_endpoint_bootstrap.ps1
```
La version doit déjà être partagée au registre (`.\scripts\80_prod_rollout.ps1 -Stage share -ModelVersion <v>`, session DEV).

**17. Publication progressive d'une nouvelle version** - jamais 100 % d'un coup. Sans Azure DevOps, étape par étape :

```powershell
.\scripts\80_prod_rollout.ps1 -Stage state            -ModelVersion <v>   # état, ne change rien
.\scripts\80_prod_rollout.ps1 -Stage share            -ModelVersion <v>   # DEV -> registre
.\scripts\80_prod_rollout.ps1 -Stage deploy_candidate -ModelVersion <v>   # 0 % + test direct
.\scripts\80_prod_rollout.ps1 -Stage mirror           -ModelVersion <v>   # copie d'une part des appels, observation
.\scripts\80_prod_rollout.ps1 -Stage canary           -ModelVersion <v>   # 90 / 10
.\scripts\80_prod_rollout.ps1 -Stage promote          -ModelVersion <v>   # 100 % candidat
.\scripts\80_prod_rollout.ps1 -Stage retire           -ModelVersion <v>   # supprime l'ancienne couleur (à 0 %)
.\scripts\80_prod_rollout.ps1 -Stage rollback         -ModelVersion <v>   # retour arrière, rien n'est supprimé
```
Entre deux étapes, regardez `scoring_results | where scored_at > ago(10m) | summarize count() by deployment, model_version`.
La couleur candidate est **calculée** (l'opposée de celle qui sert le trafic) : deux publications successives fonctionnent sans éditer de YAML.

**18. Pointer la Function sur PROD** - même URI de scoring pour l'appelant, sans interruption.

```powershell
.\scripts\73_function_target.ps1 -Target prod      # demande confirmation, vérifie dans scoring_results
```

**19. Traçabilité** - de ce que PROD sert jusqu'aux données, au code et au run d'entraînement.

```powershell
.\scripts\78_trace_lineage.ps1
```

### Niveau 2 avec Azure DevOps

Suivre [MLOPS-ADO-SETUP.md](MLOPS-ADO-SETUP.md) : projet, agent auto-hébergé, **deux connexions de service par fédération
d'identité** (clics dans le portail, aucun secret), environnement `rti-prod` avec approbation, pipelines `rti-train` et
`rti-publish` créés depuis le YAML. Reportez ensuite les Object ID des deux principaux de service dans `demo.config.env`
(`SP_DEV_OBJECT_ID`, `SP_PROD_OBJECT_ID`) puis :

```powershell
.\scripts\71_mlops_rbac.ps1            # droits sur le registre : DEV écrit, PROD lit
```
Les noms `rti-mlops-local`, `sc-rti-aml-dev`, `sc-rti-aml-prod`, `rti-prod`, `rti-train`, `rti-publish` sont des **conventions
écrites dans les YAML** : les garder, ou les changer aux deux endroits.

## 4. Chemin B - avec l'agent

L'agent **`RTI-AML-Agent`** connaît ce dépôt, ses scripts et ses pièges.

1. Ouvrir le dépôt dans VS Code, avec GitHub Copilot Chat.
2. Choisir l'agent `RTI-AML-Agent` dans le sélecteur de modes de la vue Chat. Il est défini dans
   `.claude/agents/RTI-AML-Agent.agent.md`. Si VS Code ne le propose pas, copiez ce fichier dans `.github/agents/`.
3. Lui dire par où commencer, par exemple :
   - *« Installe la démo dans mon abonnement, niveau 1. Guide-moi avec docs/QUICKSTART.md. »*
   - *« Remplis demo.config.env avec moi et lance le preflight. »*
   - *« Mon script 10 échoue avec ... ; que vérifier ? »*
   - *« Prépare la publication de la version 3 en PROD, étape par étape. »*

Ce que fait l'agent : il lit `demo.config.env` et vous pose les questions qui manquent, lance `00b_preflight`, explique chaque
étape avant de la jouer, vous fait lancer les scripts longs (déploiements) et relit l'état par une source indépendante.
Ce qu'il ne fait pas sans votre accord : supprimer, basculer du trafic réel, publier le code.

## 5. Ce qui est facultatif

Pour une première installation, vous pouvez ignorer :

| Élément | À quoi il sert |
|---|---|
| `aml/monitoring/`, `scripts/50_aml_monitoring.ps1` | supervision de dérive du modèle (hors périmètre MLOps de la démo) |
| notebook `02_retrain_and_promote`, `scripts/42_fabric_p7.ps1` | variante de la démonstration blue/green de la piste A |
| `scripts/13_diag_eventstream.ps1`, `21_aml_job_logs.ps1`, `31_probe_endpoint.py`, `34_function_diagnostics.ps1`, `35_invoke_score_once.ps1`, `66_job_diag.py` | diagnostic, à sortir en cas de panne |
| `docs/PROGRESS.md` | journal de mise au point (historique, pas une procédure) |

## 6. Démarrer et arrêter une démo déjà installée

[RUNBOOK.md](RUNBOOK.md) : reprendre la capacité, réactiver l'Eventstream, lancer le simulateur avec backfill, vérifier la boucle.
**L'ordre n'est pas négociable.**

## 7. Arrêter ce qui facture

```powershell
# Ctrl+C dans le terminal du simulateur
.\scripts\91_cost_guard.ps1                  # liste ce qui facture encore
.\scripts\91_cost_guard.ps1 -Stop            # suspend la capacité Fabric, cluster AML à min 0
.\scripts\90_teardown.ps1                    # supprime les endpoints (confirmation avant chacun)
.\scripts\90_teardown.ps1 -IncludeRegistry -IncludeProdWorkspace   # en plus: registre et workspace PROD
```
Pour tout effacer : `az group delete --name <AZURE_RESOURCE_GROUP>` (demande de confirmation), puis supprimer le workspace
Fabric dans le portail et suspendre ou supprimer la capacité.

## 8. Dépannage

| Symptôme | Cause probable | Que faire |
|---|---|---|
| `running scripts is disabled on this system` | stratégie d'exécution | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force` |
| `InvalidAuthenticationTokenTenant`, ou `ResourceGroupNotFound` pour un groupe qui existe | session `az` sur un autre tenant | `az account show`, puis `az login --tenant <AZURE_TENANT_ID>` ; redémarrer le serveur MCP s'il y en a un |
| `Missing setting ... in demo.config.env` | clé vide | la renseigner (ou `.\scripts\00a_init_config.ps1`) |
| Le script 10 ou 12 échoue, workspace inaccessible | capacité `Paused` | la reprendre et attendre `Active` ([RUNBOOK.md](RUNBOOK.md) étape 1) |
| `telemetry` ne grossit pas | destination de l'Eventstream `Paused` ou événements envoyés trop tôt | `.\scripts\15_eventstream_resume.ps1`, puis relancer le simulateur ; diagnostic : `.\scripts\13_diag_eventstream.ps1` |
| Tout est vert mais `scoring_results` ne bouge pas | pas assez d'historique : `features_now()` exige 45 minutes | `features_now() \| count` doit valoir 4 ; rejouer `--backfill-minutes 120` |
| `KeyBasedAuthenticationNotPermitted` | stratégie interdisant les clés partagées | `.\scripts\22_aml_identity_datastores.ps1` |
| Job AML en échec dès les premières secondes | cluster sans identité ou sans droit sur le stockage | `.\scripts\23_aml_compute_identity.ps1`, puis `.\scripts\21_aml_job_logs.ps1` |
| Nom de stockage ou de Function déjà pris | unicité mondiale | changer la clé dans `demo.config.env` et relancer `00b_preflight` |
| Registre refusé ou stockage du registre en accès public désactivé | stratégie d'entreprise | demander une exemption ; sinon plan B (copie tracée) |
| Un déploiement ne se supprime pas | il a du trafic | retirer le trafic d'abord, ou supprimer l'**endpoint** (`90_teardown.ps1`) |
| `rti-publish` ou `rti-train` ne démarre pas | agent hors ligne, ou connexion de service non autorisée pour ce pipeline | voir « Pièges connus » dans [MLOPS-ADO-SETUP.md](MLOPS-ADO-SETUP.md) |
| Une commande `az ml` ne sort rien | normal pour certaines (suppression, reprise) | vérifier par une lecture indépendante, jamais sur le seul code de retour |

## 9. Ce que cette démo ne fait pas

Pas d'IaC (volontairement : un chemin court de scripts `az`), pas de GitHub Actions, pas de pipelines de déploiement Fabric,
pas de réseau privé, pas de supervision de dérive dans la chaîne MLOps, un seul modèle (`temp_forecaster`), un seul site.
Pour brancher vos propres données et votre propre modèle : [MLOPS-GUIDE.md](MLOPS-GUIDE.md), section 6.

# Script de démo — MLOps DEV → PROD (6 actes, 25 min)

Référence : [MLOPS-BRIEF.md](MLOPS-BRIEF.md) §3. Sujet : la **chaîne** MLOps, pas la qualité du modèle.
Trois messages : **donnée figée**, **registre partagé**, **bascule progressive** — reliés par le lignage data ↔ code ↔ modèle.

Préambule PowerShell (tout nouveau terminal) :

```powershell
$env:PATH = "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin;$env:PATH"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
cd '<repo-root>'
```

---

## Préparation

### J-7 / J-2 (acquis)

- Workspaces `aml-rti-demo` (DEV) et `aml-rti-prod` (PROD), registre `mlr-rti-demo`, connexions `sc-rti-aml-dev` / `sc-rti-aml-prod`, environnement ADO `rti-prod` avec approbation, agent auto-hébergé `rti-mlops-local`.
- Répétition `rti-train` + `rti-publish` faite le 14/10 (voir [PROGRESS.md](PROGRESS.md)).

### J-1 / matin du jour J — dans cet ordre

| # | Action | Commande | Preuve attendue |
|---|---|---|---|
| 1 | **Endpoint PROD d'abord** (facture 24/7 dès ici) | `.\scripts\81_prod_endpoint_bootstrap.ps1` (sans argument = dernière version du registre) | `blue = 100 %`, test de fumée OK |
| 2 | Lire l'état | `.\scripts\80_prod_rollout.ps1 -Stage state -ModelVersion <v+1>` | `current: blue`, `candidate: green`, `mirror:` vide |
| 3 | Reprendre la capacité Fabric | RUNBOOK étape 1 | `properties.state = Active` |
| 4 | Réactiver l'Eventstream | `.\scripts\15_eventstream_resume.ps1` | destination `Running` |
| 5 | Simulateur avec backfill | `python simulator\sensor_producer.py --backfill-minutes 120` | `features_now() \| count` = **4** |
| 6 | Pointer la Function sur PROD | `.\scripts\73_function_target.ps1 -Target prod` | lignes `deployment = blue` dans `scoring_results` |
| 7 | Agent ADO en ligne | `<agent-dir>\rti-mlops-local\run.cmd` (laisser ouvert) | pool `rti-mlops-local` : agent *Online* |
| 8 | **Snapshot figé** (notebook `04`, identifiant vide) | Fabric → `04_snapshot_versioned` | noter `snapshot=<id>` |
| 9 | **Pré-exécuter** un `rti-train` sur ce snapshot → nouvelle version `N` | ADO → `rti-train`, `snapshotId=<id>` | `N` > version servie en PROD |

### H-1

- Pré-chauffer le cluster (sinon 5 min de silence à l'acte 4) :
  `az ml compute update -n cpu-cluster -g rg-rti-aml-demo -w aml-rti-demo --min-instances 1` — **remettre à 0 après**.
- Dashboard `rti-aml-scoring` ouvert. **Filtrer les tuiles « par `deployment` » sur une fenêtre récente (30 min)** pour ne pas mélanger les lignes DEV et PROD.
- Contrôle bloquant : `features_now() | count` = 4 et `scoring_newest` < 1 min.
- Onglets prêts : Fabric (notebook `04`), AML Studio DEV (datastore, data asset, job, modèles), registre, ADO (`rti-train`, `rti-publish`), dashboard.

> Règle de publication : la version publiée doit être **plus récente** que celle servie, sinon le stage répond « already served » et ne déploie rien.

---

## Acte 1 — Fabric : la donnée d'entraînement est figée (4 min)

- **Je montre** : `telemetry` en direct (dashboard ou KQL), puis le notebook `04` qui écrit `snapshot=<id>` (Parquet + `_manifest.json`).
- **Je dis** : « Le manifeste est écrit en dernier : sa présence = snapshot complet. Une 2e exécution avec le même identifiant est refusée. »
- **Commande** : relancer `04` avec `SNAPSHOT_ID = '<id déjà écrit>'`.
- **Attendu** : refus explicite (write-once), rien n'est modifié.
- **Plan B** : montrer le snapshot et le refus déjà obtenus (`20261013-1315`).

## Acte 2 — Connexion : aucune copie, accès gouverné (4 min)

- **Je montre** : datastore `rti_snapshots` (identité, pas de clé), navigation jusqu'à `snapshot=<id>`, rôle `Storage Blob Data Reader` de l'identité du cluster.
- **Je dis** : « La donnée ne bouge pas : AML la lit en place, avec l'identité. Aucune clé à stocker. »
- **Plan B** : captures de la page du datastore.

## Acte 3 — Version : un signet immuable (3 min)

- **Je montre** : data asset `telemetry_train:<id>` et ses **7 tags** (`site`, `window_start`, `window_end`, `row_count`, `manifest_sha256`, `source_table`, `source_delta_version`).
- **Commande** : `python scripts\72_register_snapshot_asset.py --snapshot-id <id>`
- **Attendu** : « already exists, same manifest hash » et sortie 0 — jamais d'écrasement.
- **Plan B** : page de l'asset dans Studio.

## Acte 4 — Entraînement : reproductible et comparable (6 min)

- **Je montre** : lancer `rti-train` en direct (`snapshotId=<id>`), puis commenter le run **déjà terminé** (étape 9 de la préparation) : `prep` **vérifie** le manifeste → `train` → `evaluate` (gate « bat la persistance ») → `register`. Comparer deux runs dans AML (MLflow). Montrer les tags `git_sha`, `ado_build_id`, `data_asset`.
- **Je dis** : « Le pipeline ne fait pas confiance à la donnée, il la vérifie avant d'entraîner. »
- **Gate (en différé)** : run avec `maxMae=0.1` → rejet `MAE 4.3242 vs threshold 2.0` (déjà obtenu, à montrer en différé).
- **Plan B** : le run pré-exécuté seul ; `rti-train` en direct ne sert qu'à montrer le déclenchement.

## Acte 5 — Registre : data, code et modèle reliés (4 min)

- **Je montre** : `temp_forecaster:N` et ses tags ; le même nom/version dans le registre `mlr-rti-demo` ; puis le lignage :
  `.\scripts\78_trace_lineage.ps1 -ModelVersion <N>`
- **Je dis** : « On promeut une *référence* du registre, pas une copie de fichiers. »
- **Attendu** : chaîne modèle → job AML → asset → `manifest_sha256` → commit → run ADO, exit 0.
- **Plan B** : sortie du script collée dans une diapo.

## Acte 6 — PROD : mise à jour sans interruption (4 min)

- **Je montre** : `rti-publish` (`modelVersion=<N>`, `action=promote`). Dashboard visible en parallèle : `deployment` bascule, 0 erreur.
  1. `Share` (DEV → registre, idempotent)
  2. `DeployCandidate` — **approbation `rti-prod`**, candidate à 0 %, appel direct
  3. `Mirror` 10 % — valider après lecture de `scoring_results`
  4. `Canary` 90/10 — valider
  5. `Promote` 0/100 — valider
  6. `Retire` de l'ancienne couleur (à 0 % uniquement)
- **Requête de contrôle** :

  ```kusto
  scoring_results | where scored_at > ago(10m) | summarize count() by deployment, model_version
  ```

- **Je dis** : « La Function appelle le même URI du début à la fin. Seule la répartition du trafic bouge. »
- **Rollback** : `rti-publish` avec `action=rollback` tant que l'ancienne couleur existe.
- **Plan B** : si le temps manque, s'arrêter après `Canary` et montrer le run de répétition terminé. Le split se joue **par requête** (2 tirages/min) : utiliser des bins ≥ 2 min et la table de parts cumulée.

---

## Après la démo

1. `Ctrl+C` simulateur ; `az fabric capacity suspend --resource-group fabric_rg --capacity-name <FABRIC_CAPACITY>`.
2. `cpu-cluster` à `--min-instances 0`.
3. Supprimer l'endpoint PROD (**l'endpoint, pas un déploiement**), après accord :
   `az ml online-endpoint delete --name temp-forecast-prod-ep --resource-group rg-rti-aml-demo --workspace-name aml-rti-prod --yes`
4. `.\scripts\91_cost_guard.ps1`

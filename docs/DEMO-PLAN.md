# Plan de démo — Fabric RTI × Azure Machine Learning

> **Piste A** (`P0…P8`). Le dépôt porte aussi la **piste C** — MLOps DEV → PROD piloté par Azure
> DevOps, étapes `M0…M8` — qui réutilise ce pipeline, ces scripts d'endpoint et cette Function :
> voir [MLOPS-PLAN.md](MLOPS-PLAN.md). Tout ajout fait pour la piste C est **optionnel et
> rétro-compatible** : ce plan-ci doit rester rejouable sans rien changer.
>
> La piste B (fine-tuning LoRA d'un VLM, `F0…F5`) a été **retirée du dépôt le 2026-10-07** : elle vit
> désormais dans son propre dépôt.

**Pitch (30 s)** : des capteurs industriels streament en temps réel dans Fabric RTI. On fige un snapshot versionné, on entraîne un modèle de prédiction de température dans Azure ML, on l'expose sur un endpoint managé, et une Azure Function score en continu et **réinjecte les prédictions dans le temps réel**. Puis on réentraîne et on bascule en v2 **sans rien changer côté consommateur** (blue/green).

---

## Architecture

```mermaidaz storage account update -n <STORAGE_ACCOUNT> -g rg-rti-aml-demo --public-network-access Enabled --default-action Allow --bypass AzureServices -o none
flowchart LR
  SIM[Simulateur 4 capteurs<br/>temp / humid / press / vibr] -->|Custom endpoint| ES[Eventstream<br/>es-sensors]
  ES --> EH[(Eventhouse KQL<br/>table: telemetry)]
  EH -->|OneLake availability| NB[Notebook Fabric<br/>01_snapshot_to_datastore]
  NB -->|parquet| ADLS[(ADLS Gen2<br/>datastore: rti_snapshots)]
  ADLS --> DA[AML Data asset<br/>telemetry_temp_ds:vN]
  DA --> PIPE[AML Pipeline<br/>prep -> train -> eval -> register]
  PIPE --> REG[Model registry<br/>temp_forecaster:vN]
  REG --> EP[Managed online endpoint<br/>temp-forecast-ep<br/>blue / green]
  FUNC[Azure Function<br/>timer 1 min] -->|read features| EH
  FUNC -->|POST scoring URI| EP
  FUNC -->|ingest| SC[(Eventhouse<br/>table: scoring_results)]
  SC --> DASH[Real-Time Dashboard<br/>réel vs prédit]
  EH --> DASH
```

## Décisions structurantes (verrouillées en P0)

- **IaC : aucune.** Tout est provisionné par `scripts/00_bootstrap.ps1` en `az cli` — c'est le chemin le plus court pour une démo. (Bicep écarté volontairement.)
- **Souscription : `<subscription-name>`** — `<SUBSCRIPTION_ID>`, tenant `<TENANT_ID>`.
- **Région : `westus3`** — imposée par les capacités Fabric existantes (`democapa1` F4, `<FABRIC_CAPACITY>` F32, `democapf64` F64, `copilotcapacityf64` F64, toutes dans `Fabric_RG` / `westus3`). Un workspace Fabric vit dans la région de sa capacité → on colocalise ADLS + AML + Function en `westus3` pour éviter les allers-retours inter-régions.
- **Capacité Fabric retenue : `<FABRIC_CAPACITY>` (F32, `westus3`, RG `Fabric_RG`)**.
- **Auth : identité managée** partout (Function → AML endpoint, Function → Eventhouse, AML → ADLS).
- **Ingestion : Eventstream avec source *Custom endpoint*** alimenté par le simulateur Python — 3 clics, et c'est le visuel RTI qui porte la démo.
- **Function : Python v2 (decorators), plan Flex Consumption**, déployée par `func azure functionapp publish` (pas d'azd).

## Nommage

| Élément | Nom |
|---|---|
| Resource group | `rg-rti-aml-demo` |
| Région | `westus3` |
| Fabric workspace | `ws-rti-aml-demo` |
| Eventhouse / KQL DB | `eh-sensors` / `sensors` |
| Eventstream | `es-sensors` |
| Tables KQL | `telemetry`, `scoring_results` |
| Storage ADLS Gen2 | `<STORAGE_ACCOUNT>` / filesystem `snapshots` |
| AML workspace | `aml-rti-demo` |
| Compute cluster | `cpu-cluster` (`Standard_DS3_v2`, min 0 / max 2) |
| Datastore AML | `rti_snapshots` |
| Data asset | `telemetry_temp_ds` (v1, v2) |
| Modèle | `temp_forecaster` (v1, v2) |
| Endpoint | `temp-forecast-ep` — déploiements `blue`, `green` |
| Function App | `func-rti-scorer-<SUFFIX>` (Python 3.11, Flex Consumption) |

---

## Phases

### P0 — Cadrage & prérequis  ⏱ ~10 min (hors démo, fait en amont)
- [x] Souscription et région choisies (voir « Décisions structurantes »).
- [x] `az login --tenant <TENANT_ID>` OK, souscription active positionnée.
- [x] `az extension add -n ml` → **v2.44.1** installée.
- [x] Capacités Fabric trouvées dans `Fabric_RG` / `westus3` — reste à confirmer qu'une capacité est **Active** (non « Paused ») et que tu es Admin du workspace.
- [ ] Vérifier le quota compute AML en `westus3` (`mcp_azure_mcp_ser_quota`).
- [ ] Installer `func` (Azure Functions Core Tools v4) — absent du PATH.

### P1 — Infra Azure (az cli, pas de Bicep)  ⏱ ~10 min (fait en amont)
- [x] `scripts/00_bootstrap.ps1`, idempotent, crée dans `rg-rti-aml-demo` / `westus3` :
  - ADLS Gen2 `<STORAGE_ACCOUNT>` (HNS activé) + filesystem `snapshots`
  - AML workspace `aml-rti-demo` (+ Key Vault / App Insights / Storage créés automatiquement par `az ml workspace create`)
  - compute cluster `cpu-cluster` (`Standard_DS3_v2`, min 0 / max 2)
  - datastore AML `rti_snapshots` (identity-based, sans clé)
  - Function App `func-rti-scorer-<SUFFIX>` (Python 3.11, Flex Consumption, MI système)
- [x] Exemption de policy `exempt-rti-aml-demo` sur le RG — sans elle `MCAPSGovDeployPolicies` force `publicNetworkAccess: Disabled` sur tout storage. **À supprimer au teardown.**
- [x] Rôle : AML MI (`112da00e-…`) → `Storage Blob Data Contributor` sur `<STORAGE_ACCOUNT>`.
- [ ] Rôle : Function MI (`dfe82332-…`) → `AzureML Data Scientist` sur l'endpoint (fait en P6, l'endpoint n'existe pas encore).

### P2 — Fabric RTI : ingestion temps réel  ⏱ 5 min **[DÉMO]**
- [ ] Workspace + Eventhouse `eh-sensors` (Fabric MCP).
- [ ] `fabric/kql/01_create_tables.kql` : table `telemetry` + mapping JSON + rétention.
- [ ] Eventstream `es-sensors` avec source **Custom endpoint** → destination Eventhouse (ingestion directe).
- [ ] Lancer `simulator/sensor_producer.py` (4 devices, 1 msg/s, température avec dérive + cycles + bruit → apprenable).
- [ ] **Montrer** : `telemetry | summarize count() by device_id` qui monte en direct + un graph `render timechart`.

### P3 — OneLake availability + snapshot versionné  ⏱ 5 min **[DÉMO]**
- [ ] Activer OneLake availability sur `telemetry` : `.alter table telemetry policy mirroring dataformat=delta with (IsEnabled=true)`.
- [ ] Notebook Fabric `01_snapshot_to_datastore.ipynb` :
  1. lit le delta OneLake `abfss://ws-rti-aml-demo@onelake.dfs.fabric.microsoft.com/eh-sensors.Eventhouse/Tables/telemetry`,
  2. feature engineering (lags 1/5/15 min, moyennes/écarts glissants 30 min, cible `temperature_c` à t+15 min),
  3. écrit `snapshots/telemetry/v{N}/*.parquet` dans ADLS Gen2,
  4. crée/enregistre le **Data asset AML versionné** `telemetry_temp_ds:vN` (`azure-ai-ml`),
  5. **déclenche le pipeline d'entraînement** AML.
- [ ] **Montrer** : la table KQL lisible en Delta dans OneLake, puis le Data asset v1 dans AML Studio avec sa lineage.

### P4 — Entraînement AML  ⏱ 5 min **[DÉMO]**
- [ ] `aml/pipelines/training_pipeline.yml` : `prep → train → evaluate → register`.
- [ ] `train.py` : `HistGradientBoostingRegressor` (sklearn), MLflow autolog, split temporel (pas aléatoire).
- [ ] `evaluate.py` : MAE / RMSE / R², gate `MAE < seuil` avant enregistrement.
- [ ] `register.py` : enregistre `temp_forecaster` avec tags `data_asset=telemetry_temp_ds:1`.
- [ ] **Montrer** : le graphe du pipeline, les métriques, le modèle v1 dans le registry avec la traçabilité vers le dataset.

### P5 — Déploiement endpoint (blue)  ⏱ 3 min **[DÉMO]**
- [ ] `az ml online-endpoint create -f aml/endpoints/endpoint.yml`.
- [ ] `az ml online-deployment create -f aml/endpoints/deployment-blue.yml --all-traffic` (modèle v1).
- [ ] **Montrer** : `az ml online-endpoint invoke` avec un payload de test → prédiction.

### P6 — Boucle temps réel : Function → endpoint → RTI  ⏱ 5 min **[DÉMO]**
- [ ] Table `scoring_results` + permissions Ingestor pour la MI de la Function sur la KQL DB.
- [ ] Function timer (**30 s**, pas 1 min : en dessous la bascule blue/green ne se voit pas à l'œil nu) : requête KQL des features de la dernière fenêtre → POST scoring URI (token MI) → ingestion `scoring_results` (dont l'en-tête `azureml-model-deployment`).
- [ ] Real-Time Dashboard, **4 tuiles** : (1) température live, (2) prédiction vs réel décalé de 15 min, (3) **prédictions par `deployment`** en barres empilées, (4) **MAE observée par `deployment`**.
- [ ] **Montrer** : le dashboard qui s'actualise, la prédiction qui suit la réalité, `model_version = 1`, `deployment = blue`.

### P7 — Retraining + blue/green  ⏱ 7 min **[DÉMO — le clou du spectacle]**
- [ ] Injecter un **changement de régime** dans le simulateur (nouveau device / offset thermique) → montrer la dérive sur le dashboard (l'erreur augmente).
- [ ] Rejouer le notebook → Data asset `telemetry_temp_ds:v2` → pipeline → modèle `temp_forecaster:2`.
- [ ] `deployment-green.yml` (modèle v2), création avec **0 % de trafic**, smoke test ciblé `--deployment-name green`.
- [ ] `mirror_traffic green=10` → puis `blue=90 green=10` → puis `blue=0 green=100`.
- [ ] **Montrer** : dans `scoring_results`, `model_version` qui passe de 1 → 2 et `deployment` de `blue` → `green`, **sans aucun redéploiement de la Function ni changement d'URI**. L'erreur de prédiction redescend sur le dashboard.
- [ ] (après validation) suppression de `blue`.

### P8 — Clôture  ⏱ 2 min
- [ ] Récap : gouvernance (dataset versionné + lineage), MLOps (pipeline reproductible + registry), temps réel (RTI in/out), zéro-downtime (blue/green).
- [ ] Teardown : `scripts/90_teardown.ps1` (stop simulateur, scale-to-zero, suppression endpoint, pause capacité).

---

## Monitoring — trois couches, trois questions

Ajouté le 2026-09-02. Le monitoring n'est pas *un* écran : ce sont trois dispositifs qui
repondent a des questions differentes. C'est leur articulation qui fait la demonstration.

| Couche | Question | Source | En direct ? |
|---|---|---|---|
| **A — Service** | ca repond, et **qui** repond ? | Azure Monitor, metriques d'endpoint, dimension `deployment` | oui, immediat |
| **B — Qualite** | le modele est-il encore **juste** ? | tuile KQL : MAE observee par `deployment` (jointure `scoring_results` x `telemetry` decalee de 15 min) | oui, avec 15 min de retard |
| **C — Derive** | le **monde** a-t-il change ? | AML Model Monitor : data drift, prediction drift, data quality | non, pre-calcule |

**Le message pedagogique** : *B a besoin de la verite terrain, C n'en a pas besoin.* La derive
se detecte immediatement ; l'erreur, seulement une fois le futur arrive. D'ou la necessite des
deux. Le changement de regime injecte en P7 declenche **les deux a la fois** — deux detecteurs
independants, un seul evenement.

### Contraintes verifiees dans la doc (2026-09-02)

- **Collecte de donnees sur modele MLflow : un clic dans le Studio.** AML auto-instrumente le
  scoring script et cree les data assets `<endpoint>-<deployment>-model_inputs` / `-model_outputs`.
  ⇒ **on garde le deploiement no-code**, pas de `score.py` a ecrire. Le clic est montrable.
- **Le Model Monitor tourne sur Spark, en recurrence (quotidienne recommandee).** Il n'est **pas**
  jouable en direct ⇒ couche C = « le moniteur configure + le run de la veille ». A pre-executer.
- **Risque a lever tot** : la doc demande une identite managee **assignee par l'utilisateur (UAMI)**
  sur le workspace pour l'auth sans cle du monitoring. Nous n'avons qu'une identite **systeme**.
  A tester des P7b, pas la veille.
- Le signal **Model performance (regression)** existe et calcule MAE/MSE/RMSE nativement, mais il
  est en **preview** et exige la verite terrain sous forme de data asset correle par `correlationid`.
  Trop de plomberie : c'est notre tuile KQL qui joue ce role, en temps reel et en unite metier.

### P5b — couche A  ⏱ 1 min **[DÉMO]**
- [ ] Epingler les metriques d'endpoint ventilees par `deployment`. **Verifier les noms exacts des
      metriques au moment de construire** (ne pas les inventer).

### P7b — couche C  ⏱ 2 min **[DÉMO, pre-calcule]**
- [ ] Activer la collecte de donnees sur `blue` et `green` (Studio, un clic).
- [ ] `aml/monitoring/model-monitor.yml` : reference = `telemetry_features:1`, production = donnees
      collectees ; signaux `data_drift` + `prediction_drift` + `data_quality`.
- [ ] Un run manuel la veille de la demo.
- [ ] **Montrer** : la derive detectee par AML **et** la MAE qui monte en KQL, sur le meme evenement.

---

## Déroulé condensé (25 min sur scène)

| Min | Écran | Message |
|---|---|---|
| 0–2 | Schéma d'archi | « De la donnée temps réel à la prédiction temps réel, en boucle fermée » |
| 2–6 | KQL Queryset | Ingestion live P2 |
| 6–10 | Notebook Fabric + AML Studio | Snapshot → dataset versionné P3 |
| 10–14 | AML pipeline + registry | Entraînement + modèle v1 P4 |
| 14–16 | CLI / Studio | Endpoint blue P5 |
| 16–20 | Real-Time Dashboard | Function → prédictions dans RTI P6 |
| 20–25 | Dashboard + CLI | Dérive → v2 → blue/green transparent P7 |

**Plan B si le temps manque** : pré-exécuter P1–P5 en amont, ne jouer en live que P2 (ingestion), P6 (dashboard) et P7 (blue/green) — c'est là qu'est l'effet « waouh ».

---

## Risques & parades

| Risque | Parade |
|---|---|
| **La tuile MAE est vide juste après la bascule** (la vérité terrain arrive 15 min plus tard — la tuile la plus intéressante serait blanche au pire moment) | faire tourner la boucle **≥1 h avant** la démo pour avoir de l'historique |
| **La bascule blue/green ne se voit pas** parce que le timer est trop lent | timer Function à **30 s** |
| Le Model Monitor (couche C) tourne sur Spark en récurrence quotidienne, **non jouable en live** | pré-exécuter le run la veille et le montrer comme un résultat, sans prétendre qu'il est live |
| Auth sans clé du Model Monitor : la doc exige une **UAMI** sur le workspace, nous n'avons qu'une identité système | tester en P7b, bien avant la démo |
| OneLake availability met quelques minutes à matérialiser le Delta | l'activer 30 min avant ; sinon fallback `.export` KQL vers ADLS |
| Création du managed endpoint lente (5–10 min) | créer endpoint + `blue` **en amont** ; ne jouer que `green` en live |
| Quota compute AML insuffisant | vérifier en P0, prévoir une région de repli |
| Auth Function → Eventhouse | ajouter la MI comme `Ingestor`+`Viewer` sur la KQL DB, testé en P6 avant la démo |
| Warm-up du démarrage à froid de la Function | plan Flex/Premium ou pré-lancer le timer avant la démo |

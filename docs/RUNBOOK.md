# RUNBOOK — démarrer, vérifier et arrêter la démo

Séquence opérationnelle validée le 2026-09-08. Elle suppose l'infrastructure déjà
provisionnée (P0 → P7 dans [DEMO-PLAN.md](DEMO-PLAN.md)) ; on ne fait ici que réveiller
un environnement mis en pause.

**L'ordre n'est pas négociable.** Chaque étape dépend de la précédente, et deux d'entre
elles échouent *silencieusement* si on les anticipe : l'Eventstream ne se réactive pas
tant que la capacité n'est pas réellement `Active`, et les événements envoyés avant que
la destination soit `Running` sont **perdus** — rien n'est mis en attente.

---

## Coordonnées de l'environnement

| Élément | Valeur |
|---|---|
| Souscription | `<SUBSCRIPTION_ID>` |
| Région | `westus3` |
| Capacité Fabric | `<FABRIC_CAPACITY>` (F32) dans `fabric_rg` |
| Workspace Fabric | `ws-rti-aml-demo` = `<FABRIC_WORKSPACE_ID>` |
| Base KQL | `sensors` = `<KQL_DATABASE_ID>` |
| URI Kusto | `https://<EVENTHOUSE_HOST>.z7.kusto.fabric.microsoft.com` |
| Eventstream | `es-sensors` = `<EVENTSTREAM_ID>` |
| Dashboard | `rti-aml-scoring` = `<DASHBOARD_ID>` |
| Endpoint AML | `temp-forecast-ep` (RG `rg-rti-aml-demo`, workspace `aml-rti-demo`) |
| Function App | `func-rti-scorer-<SUFFIX>` (timer 30 s) |

Les identifiants de **nœuds** d'Eventstream ne figurent pas ici volontairement : ils
changent quand un nœud est recréé. Les résoudre par `GET /topology`.

### Préambule PowerShell

Deux corrections à appliquer dans tout nouveau terminal (voir *Pièges connus*) :

```powershell
$env:PATH = "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin;$env:PATH"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
cd '<repo-root>'
```

---

## Démarrage

### 1. Reprendre la capacité Fabric

```powershell
az fabric capacity resume --resource-group fabric_rg --capacity-name <FABRIC_CAPACITY>
```

`--capacity-name` est le seul nom de paramètre accepté ; ni `--name` ni `-n`.
**La commande ne produit aucune sortie, même en cas de succès.**

Vérification — et c'est la seule qui dise la vérité :

```powershell
az rest --method get --url "https://management.azure.com/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/fabric_rg/providers/Microsoft.Fabric/capacities/<FABRIC_CAPACITY>?api-version=2023-11-01" --query "properties.state" -o tsv
```

Attendu : `Active`. Ne pas passer à la suite avant.

> Resource Graph répondra encore `Paused` pendant plusieurs minutes, et
> `az fabric capacity show` renvoie `state: null`. Se fier à l'une ou l'autre conduit à
> croire l'opération ratée et à la relancer inutilement.

### 2. Réactiver l'Eventstream

Une pause de capacité désactive les **destinations** et la reprise ne les rallume pas.
Le symptôme est trompeur : la source et le stream repassent `Running` tout seuls, donc
l'Eventstream a l'air sain alors que la table Kusto ne grossit plus.

```powershell
.\scripts\15_eventstream_resume.ps1
```

Vérification obligatoire :

```powershell
$t = az rest --method get --url "https://api.fabric.microsoft.com/v1/workspaces/<FABRIC_WORKSPACE_ID>/eventstreams/<EVENTSTREAM_ID>/topology" --resource "https://api.fabric.microsoft.com" -o json | ConvertFrom-Json
$t.destinations | ForEach-Object { "{0} = {1}" -f $_.name, $_.status }
```

Attendu : `Running`. Un état `Resuming` est normal en transition — réinterroger.

> **Si la destination est restée `Paused`, relancer le script.** Un premier appel lancé
> trop tôt après la reprise de capacité est accepté (`EXIT=0`, corps vide) sans produire
> d'effet. Le corps vide ne prouve que l'acceptation de la requête, pas la reprise.

### 3. Lancer le simulateur

Seulement une fois la destination `Running`, sinon les événements partent dans le vide.

```powershell
python simulator\sensor_producer.py --backfill-minutes 120
```

Le backfill donne à `features_now()` les 45 minutes d'historique dont il a besoin ; sans
lui, la Function ne produirait aucune prédiction avant longtemps. Laisser le processus
tourner : il enchaîne sur le flux continu (4 appareils, 1 msg/s).

Pour un entraînement plutôt qu'une démo d'inférence, préférer `--backfill-minutes 1440`
(la grille minute fusionne les rejeux, elle ne duplique pas les lignes).

### 4. Vérifier la boucle de bout en bout

**Le contrôle qui tranche est `features_now() | count`, et il est bloquant.** Les autres
peuvent tous être au vert alors que la démo est morte — voir l'encadré plus bas.

```kql
print now = now(),
      telemetry_oldest = toscalar(telemetry | where timestamp > ago(3h) | summarize min(timestamp)),
      telemetry_newest = toscalar(telemetry | summarize max(timestamp)),
      ingest_lag       = toscalar(telemetry | summarize now() - max(ingestion_time())),
      features_rows    = toscalar(features_now() | count),
      scoring_newest   = toscalar(scoring_results | summarize max(scored_at))
```

| Contrôle | Attendu | Si ce n'est pas le cas |
|---|---|---|
| `ingest_lag` | quelques secondes | revenir à l'étape 2 |
| `features_rows` | **4** | rejouer le backfill (étape 3) |
| `telemetry_oldest` | au moins 45 min d'historique | idem |
| `scoring_newest` | moins d'une minute | voir *Diagnostic* ci-dessous |

> **Piège majeur — « tout est vert mais rien n'est scoré ».** Observé le 2026-09-08 :
> capacité `Active`, Eventstream `Running`, simulateur à 21 000 événements envoyés,
> `ingest_lag` à 1,0 s… et `scoring_results` figée depuis 1 h 26. La cause : seules
> **7 minutes** d'historique étaient présentes, or `features_now()` en exige 45 (30 de
> fenêtre roulante + 15 de lag) et filtre `isnotnull(temperature_c_lag15)` — elle
> renvoyait 0 ligne, silencieusement.
>
> **`ingest_lag` mesure la fraîcheur, pas la continuité.** Une ingestion saine coexiste
> très bien avec un trou dans l'historique : le modèle a besoin de profondeur, pas
> seulement de récence. Le simulateur, qui n'avait jamais cessé d'émettre, renforçait la
> fausse impression que tout allait bien.
>
> Correctif : rejouer le backfill (étape 3). La grille minute fusionne les rejeux, elle
> ne duplique pas.

Toujours lire `ingestion_time()` **en plus** de `max(timestamp)` : ensemble, les deux
distinguent « rien n'arrive » de « ça arrive mais c'est vieux ».

### 5. Laisser accumuler avant de montrer le dashboard

Le split blue/green se joue **par requête HTTP**, et la Function n'en émet qu'une par
tick — soit 2 tirages par minute, dont les 4 lignes écrites portent toutes le même
`deployment`. Sur une minute, un 70/30 s'affiche donc très souvent comme 100/0.

Compter une dizaine de minutes avant que la répartition soit lisible. Les tuiles à
montrer sont la **5** (camembert cumulé) et la **6** (table des parts) ; la tuile 3 reste
bruitée par construction, même en bins de 2 minutes.

---

## Pendant la démo — basculer le trafic

```powershell
.\scripts\41_aml_traffic.ps1 -Show
.\scripts\41_aml_traffic.ps1 -Blue 0 -Green 100
```

La Function continue d'appeler **le même URI de scoring** pendant toute la bascule :
c'est précisément ce que la démo doit faire voir. Le déploiement réellement servi est lu
dans l'en-tête de réponse `azureml-model-deployment` et écrit dans
`scoring_results.deployment` — le dashboard reflète donc le basculement sans qu'aucune
configuration côté client n'ait changé.

---

## Arrêt

1. `Ctrl+C` dans le terminal du simulateur.
2. Suspendre la capacité — c'est le poste de coût dominant :

```powershell
az fabric capacity suspend --resource-group fabric_rg --capacity-name <FABRIC_CAPACITY>
```

Le déploiement `green` continue de facturer une instance `Standard_DS2_v2` en continu,
indépendamment de Fabric. Le supprimer si l'environnement dort plusieurs jours — **en deux
temps, l'ordre est imposé par le service** :

```powershell
# 1. retirer le trafic : un deploiement a poids non nul est INDESTRUCTIBLE
.\scripts\41_aml_traffic.ps1 -Blue 100 -Green 0

# 2. supprimer
az ml online-deployment delete --name green --endpoint-name temp-forecast-ep -g rg-rti-aml-demo -w aml-rti-demo --yes
```

Sauter l'étape 1 produit un `BadRequest` verbeux dont le message utile est enfoui dans
`Exception Details` : *« Can't delete deployment [green] with non-zero traffic weight,
Current traffic [30] »*.

> **Conséquence pour la démo suivante.** L'endpoint reste à `blue=100`. Une démo
> blue/green exige donc de **recréer `green` puis de rétablir le split** :
>
> ```powershell
> .\scripts\30_aml_endpoint.ps1 -DeploymentName green -DeploymentFile aml\endpoints\deployment-green.yml -ModelVersion 6 -SkipTraffic
> .\scripts\41_aml_traffic.ps1 -Blue 70 -Green 30
> ```
>
> Compter le temps de création d'un déploiement : ce n'est pas une opération à lancer
> juste avant une présentation.

**La suppression ne produit aucune sortie en cas de succès** — ne pas la confondre avec le
terminal muet. Vérifier par une source indépendante du shell :

```powershell
az ml online-deployment list --endpoint-name temp-forecast-ep -g rg-rti-aml-demo -w aml-rti-demo --query "[].name" -o json
```

---

## Diagnostic

**La télémétrie n'arrive pas.** Regarder d'abord le compteur `N events sent` du
simulateur : `send_batch` lève une exception si l'envoi échoue, donc un compteur qui
monte prouve que le point de terminaison accepte. Le problème est alors en aval —
destination d'Eventstream, ou capacité — et surtout pas dans la chaîne de connexion.

**La télémétrie arrive mais rien n'est scoré.** Exécuter `features_now()` à la main. La
fonction filtre les appareils dont les lags sont nuls : un appareil en cours de chauffe
ne produit aucune ligne, ce qui est le comportement voulu. Si elle renvoie 4 lignes et
que `scoring_results` reste figée, passer aux traces de la Function
(`scripts/34_function_diagnostics.ps1`).

**`getaddrinfo failed` sur l'Eventhouse.** L'endpoint disparaît du DNS quand la capacité
est en pause. Vérifier l'étape 1 avant de chercher un problème réseau.

---

## Pièges connus de l'environnement local

| Symptôme | Cause | Correctif |
|---|---|---|
| `az` introuvable | le terminal intégré perd le `PATH` | préfixer la ligne `$env:PATH` du préambule |
| `.ps1` refusé, `UnauthorizedAccess` | ExecutionPolicy | `Set-ExecutionPolicy -Scope Process Bypass -Force` |
| « Command produced no output » | le terminal devient muet par intermittence | ne rien conclure : revérifier l'état par un autre appel |

Ces trois-là expliquent la majorité des faux diagnostics. En particulier, **une absence
de sortie n'est jamais une preuve d'échec** dans cet environnement.

# rti-aml-demo

Démonstration de bout en bout sur Microsoft Fabric Real-Time Intelligence et Azure Machine Learning.

- **Piste A** : télémétrie temps réel -> modèle de régression -> endpoint managé -> écriture des prédictions dans l'Eventhouse -> bascule blue/green. Plan : [docs/DEMO-PLAN.md](docs/DEMO-PLAN.md).
- **Piste C (MLOps DEV -> PROD)** : données figées et versionnées, entraînement piloté par Azure DevOps, registre partagé, publication progressive en PROD sans interruption du scoring. Guide : [docs/MLOPS-GUIDE.md](docs/MLOPS-GUIDE.md).

## Installer la démo chez vous

**[docs/QUICKSTART.md](docs/QUICKSTART.md)** : prérequis, configuration, installation pas à pas (chemin manuel ou assisté par l'agent), arrêt des coûts, dépannage.

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
az login --tenant <votre-tenant-id>
.\scripts\00a_init_config.ps1     # prépare demo.config.env
# ... compléter demo.config.env ...
.\scripts\00b_preflight.ps1       # contrôle lecture seule, ne crée rien
.\scripts\00_bootstrap.ps1        # puis la suite du QUICKSTART
```

- **Tous les paramètres sont dans un seul fichier, [demo.config.env](demo.config.env)** (aucun secret). Les scripts le lisent ; une variable d'environnement `RTI_<CLE>` le surcharge.
- **Agent VS Code** : `RTI-AML-Agent` ([.claude/agents/RTI-AML-Agent.agent.md](.claude/agents/RTI-AML-Agent.agent.md)) guide l'installation et l'exploitation (section 4 du QUICKSTART).

## Contenu

| Dossier | Contenu |
|---|---|
| `fabric/` | requêtes KQL, Eventstream, notebooks (snapshot versionné), tableau de bord |
| `aml/` | composants et pipeline d'entraînement, environnement, endpoints, registre |
| `devops/` | pipelines Azure DevOps `rti-train` et `rti-publish`, gabarits |
| `functions/` | Azure Function de scoring (même URI quel que soit le déploiement) |
| `simulator/` | producteur de télémétrie simulée |
| `scripts/` | création des ressources et opérations, un script par action (numérotés) ; `scripts/lib/` lit la configuration |
| `docs/` | quickstart, guide MLOps, plans, procédure de démarrage / arrêt, journal complet |

Autres documents : [docs/MLOPS-ADO-SETUP.md](docs/MLOPS-ADO-SETUP.md) (mise en place Azure DevOps),
[docs/RUNBOOK.md](docs/RUNBOOK.md) (démarrer et arrêter la démo), [docs/PROGRESS.md](docs/PROGRESS.md) (journal).

Attention aux coûts : un endpoint managé et le registre AML facturent en continu, et la capacité Fabric doit être
mise en pause hors démonstration (`scripts/91_cost_guard.ps1`, `scripts/90_teardown.ps1`).

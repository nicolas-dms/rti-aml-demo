# rti-aml-demo

Démonstration de bout en bout sur Microsoft Fabric Real-Time Intelligence et Azure Machine Learning.

- **Piste A** : télémétrie temps réel -> modèle de régression -> endpoint managé -> écriture des prédictions dans l'Eventhouse -> bascule blue/green. Plan : [docs/DEMO-PLAN.md](docs/DEMO-PLAN.md).
- **Piste C (MLOps DEV -> PROD)** : données figées et versionnées, entraînement piloté par Azure DevOps, registre partagé, publication progressive en PROD sans interruption du scoring. **Commencer par [docs/MLOPS-GUIDE.md](docs/MLOPS-GUIDE.md).**

| Dossier | Contenu |
|---|---|
| `fabric/` | requêtes KQL, Eventstream, notebooks (snapshot versionné), tableau de bord |
| `aml/` | composants et pipeline d'entraînement, environnement, endpoints, registre |
| `devops/` | pipelines Azure DevOps `rti-train` et `rti-publish`, gabarits |
| `functions/` | Azure Function de scoring (même URI quel que soit le déploiement) |
| `simulator/` | producteur de télémétrie simulée |
| `scripts/` | création des ressources et opérations, un script par action (numérotés) |
| `docs/` | guide MLOps, plans, procédure de démarrage / arrêt, journal complet |

Autres documents : [docs/MLOPS-ADO-SETUP.md](docs/MLOPS-ADO-SETUP.md) (mise en place Azure DevOps),
[docs/RUNBOOK.md](docs/RUNBOOK.md) (démarrer et arrêter la démo), [docs/PROGRESS.md](docs/PROGRESS.md) (journal).

Attention aux coûts : un endpoint managé et le registre AML facturent en continu, et la capacité Fabric doit être
mise en pause hors démonstration. Voir la section 7 du guide MLOps.

## Placeholders

Identifiers specific to the original environment were replaced by placeholders (<SUBSCRIPTION_ID>, <TENANT_ID>, <FABRIC_WORKSPACE_ID>, <KQL_DATABASE_ID>, <EVENTSTREAM_ID>, <EVENTHOUSE_HOST>, <STORAGE_ACCOUNT>, <FABRIC_CAPACITY>, <ADO_ORG>, ...).
Replace them with the values of your own environment before running the scripts and notebooks. No secret is stored in this repository.
This is a demo, not production code.

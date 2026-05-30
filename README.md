# Teams FAQ Bot

A Microsoft Teams bot, written in TypeScript with the
[Teams AI Library](https://github.com/microsoft/teams-ai), that answers FAQs
using **retrieval-augmented generation (RAG)** over a local FAQ markdown file
with **Azure OpenAI**.

It runs as an Azure Container App and uses a **user-assigned managed identity
(UAMI)** for everything — Bot Framework auth, Azure OpenAI access, and ACR
image pull. No client secrets or certificates anywhere.

## How it works

1. On startup the bot reads `data/faq.md`, splits it on `## ` headings into
   chunks, and embeds each chunk via Azure OpenAI embeddings. Vectors are
   kept in memory.
2. For every incoming user message, the bot embeds the question, finds the
   top-K most similar FAQ chunks (cosine similarity), and injects them into
   the chat prompt as grounding context.
3. The chat model (e.g. `gpt-5.4`) is instructed to answer **only** from
   those snippets, or say it doesn't know.

## Project layout

```
src/
  index.ts            # restify server + Bot Framework CloudAdapter
  bot.ts              # Teams AI Application, planner, prompt manager
  faqDataSource.ts    # Custom DataSource: embeddings + retrieval
  azureAuth.ts        # DefaultAzureCredential / UAMI token provider
  openaiPatch.ts      # Reasoning-model param scrubbing (o1/o3/o4/gpt-5)
  config.ts           # Env loading
  prompts/chat/       # Prompt template (skprompt.txt + config.json)
data/
  faq.md              # Replace with your own FAQ content
appPackage/
  manifest.json       # Teams app manifest (sideload into Teams)
infra/
  infra.bicep         # UAMI, ACR, Log Analytics, Container Apps Env, RBAC
  app.bicep           # Container App + Azure Bot (UserAssignedMSI)
  *.bicepparam        # Parameter files
scripts/
  deploy.ps1          # Full bootstrap: infra -> build image -> app
  build-image.ps1     # Rebuild + push image via ACR Tasks
  update.ps1          # Quick code redeploy (build + roll Container App)
  generate-cert.js    # (Unused for UAMI; kept for cert-auth scenarios)
Dockerfile
.dockerignore
env/.env.local.sample # Copy to env/.env.local for local dev
```

## Local development

### Prerequisites

- Node.js 18+
- An Azure OpenAI resource with a chat deployment + an embedding deployment
- `az login` (used by `DefaultAzureCredential` for AOAI when no API key is set)

### Run

```powershell
npm install
cp env/.env.local.sample env/.env.local
# Fill in AZURE_OPENAI_* values
npm run build
npm start
```

The bot listens on `http://localhost:3978/api/messages`. Test it with the
[Bot Framework Emulator](https://github.com/microsoft/BotFramework-Emulator/releases).

AOAI auth modes (selected automatically):

| Local env | Effect |
|---|---|
| `AZURE_OPENAI_API_KEY` set | API key auth |
| `AZURE_OPENAI_API_KEY` blank + `az login` done | DefaultAzureCredential (AAD) |
| `AZURE_CLIENT_ID` set | Force a specific UAMI (e.g. in container) |

## Azure deployment

All infrastructure is defined in Bicep and orchestrated by PowerShell scripts.

### Topology

```
┌──────────────────┐
│ Azure Bot        │  UserAssignedMSI ─── UAMI ──┐
│ bot-<prefix>     │  endpoint -> CA ingress     │
└────────┬─────────┘                             │
         │                                       │
         v                                       │
┌──────────────────┐  ACR pull (UAMI) ┌──────────┴─────────┐
│ Container App    │ <─────────────── │ ACR <acrName>      │
│ ca-<prefix>      │                  └────────────────────┘
│  - PORT 3978     │  Cognitive Services OpenAI User (UAMI)
│  - UAMI bound    │ ──────────────► AOAI <existing acct>
└────────┬─────────┘
         │
         v
┌──────────────────┐  Logs ──► ┌──────────────────────────┐
│ CAE cae-<prefix> │           │ Log Analytics log-<pref> │
└──────────────────┘           └──────────────────────────┘
```

### Prerequisites

- An existing Azure OpenAI account in the target resource group.
  - Default deployments expected: `gpt-5.4` (chat), `text-embedding-3-large` (embed).
  - Change via `chatDeployment` / `embeddingDeployment` parameters in
    `infra/app.bicepparam` (or `-p ...` on the CLI).
- Permissions in the target subscription:
  - `Contributor` to create the resources
  - `Owner` or `User Access Administrator` to grant the role assignments
    declared in `infra.bicep` (UAMI → AcrPull on ACR, UAMI → AOAI User on AOAI)

  If your tenant gates these via PIM, elevate before running `deploy.ps1`.
- Azure CLI 2.50+ with the `containerapp` extension and the `bicep` add-on:

  ```powershell
  az extension add --name containerapp
  az bicep install
  ```

- Resource providers registered (one-time):

  ```powershell
  az provider register -n Microsoft.App
  az provider register -n Microsoft.BotService
  az provider register -n Microsoft.ContainerRegistry
  az provider register -n Microsoft.OperationalInsights
  ```

### First-time deploy

```powershell
# Uses the defaults baked into the scripts and bicepparam files
./scripts/deploy.ps1

# Or with overrides
./scripts/deploy.ps1 `
    -SubscriptionId  <sub-guid> `
    -ResourceGroup   my-rg `
    -Location        westus3 `
    -NamePrefix      my-faqbot `
    -AcrName         myfaqbotacr `
    -AoaiAccountName my-aoai `
    -ImageTag        0.1.0
```

What `deploy.ps1` does:

1. `az group create` — ensure RG exists (idempotent).
2. `az deployment group create -f infra/infra.bicep` — UAMI, ACR, Log
   Analytics, Container Apps environment, and role assignments
   (UAMI → AcrPull on ACR, UAMI → Cognitive Services OpenAI User on the
   existing AOAI account).
3. `az acr build` — builds the Dockerfile inside ACR Tasks (no local Docker
   needed) and pushes `<acr>/teams-faq-bot:<tag>` + `:latest`.
4. `az deployment group create -f infra/app.bicep` — creates/updates the
   Container App (binds the UAMI, sets env vars, pulls the image using UAMI)
   and the Azure Bot (`UserAssignedMSI` type, messaging endpoint wired to the
   Container App FQDN).

On completion the script prints:
- Container App URL
- Health probe URL
- Bot Framework messaging endpoint
- Direct portal link to **Test in Web Chat**

### Subsequent code/FAQ updates

```powershell
./scripts/update.ps1                  # build :latest, roll Container App
./scripts/update.ps1 -ImageTag 0.2.0  # immutable tag + :latest
```

### Build image only (no deploy)

```powershell
./scripts/build-image.ps1 -ImageTag 0.2.0
```

### Re-running the full bootstrap

`./scripts/deploy.ps1` is **idempotent**. Re-running it diffs against existing
state via Bicep — unchanged resources are no-ops. Useful when you change a
parameter (e.g. swap an AOAI deployment) or add a new env var.

### Resource naming

Every resource name is derived from `-NamePrefix`:

| Resource | Pattern |
|---|---|
| UAMI | `id-<prefix>` |
| Log Analytics | `log-<prefix>` |
| Container Apps Env | `cae-<prefix>` |
| Container App | `ca-<prefix>` |
| Azure Bot | `bot-<prefix>` |
| ACR | passed separately via `-AcrName` (globally unique, alphanumeric, 5–50 chars) |

## Testing the deployed bot

1. Azure Portal → your Bot resource (`bot-<prefix>`) → **Test in Web Chat**.
2. Ask a question like "What are the support hours?" — the bot answers from
   `data/faq.md`.

### Sideload into Teams

1. Edit `appPackage/manifest.json` if needed (icons, names). `botId` is
   pre-populated with the UAMI client ID.
2. Add two PNG icons next to the manifest: `color.png` (192×192) and
   `outline.png` (32×32 transparent).
3. Zip the three files and upload via Teams → **Apps → Manage your apps →
   Upload an app**.

## Updating the FAQ

The FAQ is shipped inside the image (`data/faq.md`). To change it:

1. Edit `data/faq.md`. Each FAQ starts with `## Question`.
2. `./scripts/update.ps1` — builds a new image and rolls the Container App.

The bot re-embeds the file at startup; the new revision is live as soon as
the rollout completes.

## Tuning

| Knob | Where |
|---|---|
| Retrieval top-K | `FAQ_TOP_K` env var (default 4) — set in `app.bicep` |
| Reasoning-model handling | `forceReasoningModel` Bicep param / `AZURE_OPENAI_REASONING_MODEL` env |
| Chat / embedding deployments | `chatDeployment` / `embeddingDeployment` in `app.bicepparam` |
| Container resources | `cpu` / `memory` in `app.bicep` |
| Replicas | `minReplicas` / `maxReplicas` in `app.bicep` |
| Prompt persona / fallback message | `src/prompts/chat/skprompt.txt` |

## Notes & caveats

- The vector index is in memory; restarting a replica re-embeds the FAQ.
  Fine for hundreds of entries; for thousands, swap `FAQDataSource` for
  Azure AI Search.
- `MemoryStorage` is used for conversation state. For production, swap to
  `BlobsStorage` or `CosmosDbPartitionedStorage`.
- If you bootstrapped resources manually before adopting Bicep, you may end
  up with two role assignments per resource (CLI-generated random GUID +
  Bicep deterministic GUID). They are harmless duplicates — delete the old
  ones if you care.
- Tenants with Entra app-management policies that forbid client secrets and
  certificates (the original reason this project uses UAMI) do not block
  UAMI auth — managed identities are governed separately.

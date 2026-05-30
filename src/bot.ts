import * as path from "path";
import { MemoryStorage, TurnContext } from "botbuilder";
import {
    Application,
    ActionPlanner,
    OpenAIModel,
    PromptManager,
} from "@microsoft/teams-ai";
import { config } from "./config";
import { FAQDataSource } from "./faqDataSource";
import { patchOpenAIModelForReasoning } from "./openaiPatch";
import { buildAzureOpenAITokenProvider } from "./azureAuth";

const promptsFolder = path.join(__dirname, "prompts");

const modelOpts: ConstructorParameters<typeof OpenAIModel>[0] = {
    azureEndpoint: config.azureOpenAI.endpoint,
    azureApiVersion: config.azureOpenAI.apiVersion,
    azureDefaultDeployment: config.azureOpenAI.chatDeployment,
    useSystemMessages: true,
    logRequests: false,
};
if (config.azureOpenAI.apiKey) {
    modelOpts.azureApiKey = config.azureOpenAI.apiKey;
    console.log("[aoai] Using API key auth.");
} else {
    modelOpts.azureADTokenProvider = buildAzureOpenAITokenProvider(
        config.azureOpenAI.managedIdentityClientId
    );
    console.log(
        config.azureOpenAI.managedIdentityClientId
            ? `[aoai] Using UAMI auth (client id ${config.azureOpenAI.managedIdentityClientId}).`
            : "[aoai] Using DefaultAzureCredential auth."
    );
}
const model = new OpenAIModel(modelOpts);

// Normalize requests for newer reasoning models (o1/o3/o4/gpt-5 family) that
// reject `max_tokens` and custom temperature/top_p/penalties. See openaiPatch.ts.
patchOpenAIModelForReasoning(model, {
    forceReasoning: config.azureOpenAI.forceReasoning,
});

const prompts = new PromptManager({ promptsFolder });

const planner = new ActionPlanner({
    model,
    prompts,
    defaultPrompt: "chat",
});

const faqDataSource = new FAQDataSource({
    name: "faq",
    faqFile: config.rag.faqFile,
    topK: config.rag.topK,
    endpoint: config.azureOpenAI.endpoint,
    apiVersion: config.azureOpenAI.apiVersion,
    embeddingDeployment: config.azureOpenAI.embeddingDeployment,
    apiKey: config.azureOpenAI.apiKey || undefined,
    managedIdentityClientId: config.azureOpenAI.managedIdentityClientId || undefined,
});
prompts.addDataSource(faqDataSource);

export const app = new Application({
    storage: new MemoryStorage(),
    ai: { planner },
});

app.conversationUpdate("membersAdded", async (context: TurnContext) => {
    const added = context.activity.membersAdded ?? [];
    for (const m of added) {
        if (m.id !== context.activity.recipient.id) {
            await context.sendActivity(
                "Hi! I'm your FAQ bot. Ask me a question and I'll answer using our FAQ knowledge base."
            );
        }
    }
});

app.message("/reset", async (context, state) => {
    state.deleteConversationState();
    await context.sendActivity("Conversation reset.");
});

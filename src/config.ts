import * as dotenv from "dotenv";
import * as path from "path";
import * as fs from "fs";

const envPath = path.resolve(process.cwd(), "env", ".env.local");
if (fs.existsSync(envPath)) {
    dotenv.config({ path: envPath });
} else {
    dotenv.config();
}

function required(name: string): string {
    const v = process.env[name];
    if (!v || v.trim() === "") {
        throw new Error(`Missing required environment variable: ${name}`);
    }
    return v;
}

export const config = {
    port: parseInt(process.env.PORT || "3978", 10),

    bot: {
        id: process.env.BOT_ID || "",
        password: process.env.BOT_PASSWORD || "",
        tenantId: process.env.BOT_TENANT_ID || "",
        type: process.env.BOT_TYPE || "MultiTenant",
        certPath: process.env.BOT_CERT_PATH || "",
        certKeyPath: process.env.BOT_CERT_KEY_PATH || "",
        certThumbprint: process.env.BOT_CERT_THUMBPRINT || "",
    },

    azureOpenAI: {
        endpoint: required("AZURE_OPENAI_ENDPOINT").replace(/\/$/, ""),
        // Optional. If unset, the bot uses DefaultAzureCredential (managed identity in Azure,
        // az login locally) to obtain an AAD token for the cognitive services scope.
        apiKey: process.env.AZURE_OPENAI_API_KEY || "",
        apiVersion: process.env.AZURE_OPENAI_API_VERSION || "2024-06-01",
        chatDeployment: required("AZURE_OPENAI_CHAT_DEPLOYMENT"),
        embeddingDeployment: required("AZURE_OPENAI_EMBEDDING_DEPLOYMENT"),
        // Optional. UAMI client ID — when set, DefaultAzureCredential prefers this identity.
        managedIdentityClientId: process.env.AZURE_CLIENT_ID || "",
        // Set to "true" to force reasoning-model param scrubbing (o1/o3/o4/gpt-5 family).
        // If unset, the patch auto-detects by deployment name prefix.
        forceReasoning:
            (process.env.AZURE_OPENAI_REASONING_MODEL || "").toLowerCase() === "true",
    },

    rag: {
        faqFile: process.env.FAQ_FILE || "data/faq.md",
        topK: parseInt(process.env.FAQ_TOP_K || "4", 10),
    },
};

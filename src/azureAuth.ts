import {
    DefaultAzureCredential,
    getBearerTokenProvider,
    ManagedIdentityCredential,
    type TokenCredential,
} from "@azure/identity";

const AOAI_SCOPE = "https://cognitiveservices.azure.com/.default";

/**
 * Builds a credential suitable for Azure OpenAI access.
 *
 * - In Azure (Container App with UAMI), `AZURE_CLIENT_ID` is automatically
 *   injected and DefaultAzureCredential picks the right identity.
 * - Locally, falls back to az CLI / VS Code / etc. via DefaultAzureCredential.
 */
export function buildAzureCredential(managedIdentityClientId?: string): TokenCredential {
    if (managedIdentityClientId) {
        return new ManagedIdentityCredential({ clientId: managedIdentityClientId });
    }
    return new DefaultAzureCredential();
}

export function buildAzureOpenAITokenProvider(
    managedIdentityClientId?: string
): () => Promise<string> {
    const credential = buildAzureCredential(managedIdentityClientId);
    return getBearerTokenProvider(credential, AOAI_SCOPE);
}

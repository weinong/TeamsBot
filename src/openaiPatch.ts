import { OpenAIModel } from "@microsoft/teams-ai";

/**
 * Newer OpenAI / Azure OpenAI reasoning models (o1, o3, o4, gpt-5 families)
 * reject the legacy `max_tokens` parameter and only accept the default
 * `temperature`, `top_p`, and penalty values. The Teams AI library currently
 * only auto-handles model names starting with `o1-`, so deployments named
 * e.g. `gpt-5.4` or `o3-mini` blow up with:
 *
 *   400 Unsupported parameter: 'max_tokens' is not supported with this model.
 *
 * This helper monkey-patches the underlying `openai` SDK client that
 * `OpenAIModel` creates internally so requests are normalized before they
 * hit the API.
 */
export interface ReasoningPatchOptions {
    /**
     * Force-treat the model as a reasoning model (strip temperature/top_p/penalties).
     * If omitted, detection is by model/deployment name prefix.
     */
    forceReasoning?: boolean;
}

const REASONING_NAME_RE = /^(o\d|gpt-?5)/i;

export function patchOpenAIModelForReasoning(
    model: OpenAIModel,
    options: ReasoningPatchOptions = {}
): void {
    const anyModel = model as unknown as { _client: any };
    const client = anyModel._client;
    if (!client?.chat?.completions?.create) {
        throw new Error("patchOpenAIModelForReasoning: could not find chat.completions.create on the underlying client");
    }

    const original = client.chat.completions.create.bind(client.chat.completions);

    client.chat.completions.create = (params: any, requestOptions?: any) => {
        const isReasoning =
            options.forceReasoning === true ||
            REASONING_NAME_RE.test(String(params?.model ?? ""));

        if (params && params.max_tokens != null) {
            if (params.max_completion_tokens == null) {
                params.max_completion_tokens = params.max_tokens;
            }
            delete params.max_tokens;
        }

        if (isReasoning && params) {
            delete params.temperature;
            delete params.top_p;
            delete params.presence_penalty;
            delete params.frequency_penalty;
        }

        return original(params, requestOptions);
    };
}

import * as fs from "fs";
import * as path from "path";
import { TurnContext } from "botbuilder";
import { DataSource, Memory, RenderedPromptSection, Tokenizer } from "@microsoft/teams-ai";
import { AzureOpenAI } from "openai";
import { buildAzureOpenAITokenProvider } from "./azureAuth";

interface FAQChunk {
    title: string;
    body: string;
    text: string;
    embedding: number[];
}

export interface FAQDataSourceOptions {
    name: string;
    faqFile: string;
    topK: number;
    endpoint: string;
    apiVersion: string;
    embeddingDeployment: string;
    // Provide either apiKey, or leave blank to use AAD (managed identity / az login).
    apiKey?: string;
    // Optional UAMI client ID for in-Azure usage.
    managedIdentityClientId?: string;
}

export class FAQDataSource implements DataSource {
    public readonly name: string;
    private readonly opts: FAQDataSourceOptions;
    private readonly client: AzureOpenAI;
    private chunks: FAQChunk[] = [];
    private ready: Promise<void>;

    constructor(opts: FAQDataSourceOptions) {
        this.name = opts.name;
        this.opts = opts;
        const clientOpts: ConstructorParameters<typeof AzureOpenAI>[0] = {
            endpoint: opts.endpoint,
            apiVersion: opts.apiVersion,
            deployment: opts.embeddingDeployment,
        };
        if (opts.apiKey) {
            clientOpts.apiKey = opts.apiKey;
        } else {
            clientOpts.azureADTokenProvider = buildAzureOpenAITokenProvider(
                opts.managedIdentityClientId
            );
        }
        this.client = new AzureOpenAI(clientOpts);
        this.ready = this.initialize();
    }

    private async initialize(): Promise<void> {
        const filePath = path.resolve(process.cwd(), this.opts.faqFile);
        if (!fs.existsSync(filePath)) {
            console.warn(`[FAQDataSource] FAQ file not found: ${filePath}`);
            return;
        }
        const raw = fs.readFileSync(filePath, "utf8");
        const parsed = this.splitChunks(raw);
        if (parsed.length === 0) {
            console.warn(`[FAQDataSource] No chunks parsed from ${filePath}`);
            return;
        }

        console.log(`[FAQDataSource] Embedding ${parsed.length} FAQ chunks...`);
        const inputs = parsed.map((c) => c.text);
        const resp = await this.client.embeddings.create({
            model: this.opts.embeddingDeployment,
            input: inputs,
        });
        this.chunks = parsed.map((c, i) => ({
            ...c,
            embedding: resp.data[i].embedding,
        }));
        console.log(`[FAQDataSource] Indexed ${this.chunks.length} chunks.`);
    }

    private splitChunks(markdown: string): Omit<FAQChunk, "embedding">[] {
        const lines = markdown.split(/\r?\n/);
        const out: Omit<FAQChunk, "embedding">[] = [];
        let title = "";
        let buf: string[] = [];

        const flush = () => {
            const body = buf.join("\n").trim();
            if (title && body) {
                out.push({ title, body, text: `${title}\n${body}` });
            }
            buf = [];
        };

        for (const line of lines) {
            const m = /^##\s+(.*)/.exec(line);
            if (m) {
                flush();
                title = m[1].trim();
            } else if (title) {
                buf.push(line);
            }
        }
        flush();
        return out;
    }

    public async renderData(
        _context: TurnContext,
        memory: Memory,
        tokenizer: Tokenizer,
        maxTokens: number
    ): Promise<RenderedPromptSection<string>> {
        await this.ready;

        const query = (memory.getValue("temp.input") as string) || "";
        if (!query || this.chunks.length === 0) {
            return { output: "", length: 0, tooLong: false };
        }

        const qEmbed = await this.client.embeddings.create({
            model: this.opts.embeddingDeployment,
            input: query,
        });
        const qv = qEmbed.data[0].embedding;

        const scored = this.chunks
            .map((c) => ({ chunk: c, score: cosine(qv, c.embedding) }))
            .sort((a, b) => b.score - a.score)
            .slice(0, this.opts.topK);

        let used = 0;
        const parts: string[] = [];
        for (const { chunk } of scored) {
            const snippet = `### ${chunk.title}\n${chunk.body}\n`;
            const tokens = tokenizer.encode(snippet).length;
            if (used + tokens > maxTokens) break;
            parts.push(snippet);
            used += tokens;
        }

        const output = parts.join("\n");
        return {
            output,
            length: tokenizer.encode(output).length,
            tooLong: false,
        };
    }
}

function cosine(a: number[], b: number[]): number {
    let dot = 0;
    let na = 0;
    let nb = 0;
    for (let i = 0; i < a.length; i++) {
        dot += a[i] * b[i];
        na += a[i] * a[i];
        nb += b[i] * b[i];
    }
    const d = Math.sqrt(na) * Math.sqrt(nb);
    return d === 0 ? 0 : dot / d;
}

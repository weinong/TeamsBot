import * as fs from "fs";
import * as crypto from "crypto";
import * as restify from "restify";
import {
    CloudAdapter,
    ConfigurationServiceClientCredentialFactory,
    ConfigurationBotFrameworkAuthentication,
    TurnContext,
} from "botbuilder";
import { CertificateServiceClientCredentialsFactory } from "botframework-connector";
import { config } from "./config";
import { app } from "./bot";
import { patchJwksRefresh } from "./jwksPatch";

patchJwksRefresh();

function buildCredentialsFactory() {
    const { id, password, tenantId, type, certPath, certKeyPath, certThumbprint } = config.bot;

    if (certPath && certKeyPath) {
        if (!id) {
            throw new Error("BOT_ID is required when using certificate authentication.");
        }
        if (!fs.existsSync(certPath)) {
            throw new Error(`BOT_CERT_PATH does not exist: ${certPath}`);
        }
        if (!fs.existsSync(certKeyPath)) {
            throw new Error(`BOT_CERT_KEY_PATH does not exist: ${certKeyPath}`);
        }

        const certPem = fs.readFileSync(certPath, "utf8");
        const keyPem = fs.readFileSync(certKeyPath, "utf8");

        let thumbprint = certThumbprint.replace(/[:\s]/g, "").toUpperCase();
        if (!thumbprint) {
            // Compute SHA-1 thumbprint from the public cert (matches the value
            // Azure shows after uploading the .cer to your Entra app).
            const x509 = new crypto.X509Certificate(certPem);
            thumbprint = x509.fingerprint.replace(/:/g, "").toUpperCase();
            console.log(`[auth] Computed cert thumbprint: ${thumbprint}`);
        }

        const isSingleTenant = type.toLowerCase() === "singletenant";
        if (isSingleTenant && !tenantId) {
            throw new Error("BOT_TENANT_ID is required for SingleTenant certificate auth.");
        }

        console.log("[auth] Using certificate-based credentials.");
        return new CertificateServiceClientCredentialsFactory(
            id,
            thumbprint,
            keyPem,
            tenantId || undefined
        );
    }

    console.log(`[auth] Using ${type} credentials (app-password / managed identity).`);
    return new ConfigurationServiceClientCredentialFactory({
        MicrosoftAppId: id,
        MicrosoftAppPassword: password,
        MicrosoftAppType: type,
        MicrosoftAppTenantId: tenantId,
    });
}

const credentialsFactory = buildCredentialsFactory();

const botFrameworkAuthentication = new ConfigurationBotFrameworkAuthentication(
    {},
    credentialsFactory
);

const adapter = new CloudAdapter(botFrameworkAuthentication);

adapter.use(async (context, next) => {
    const originalSend = context.sendActivities.bind(context);
    context.sendActivities = async (activities) => {
        try {
            return await originalSend(activities);
        } catch (err) {
            console.error(`[send] FAILED:`, err);
            throw err;
        }
    };
    await next();
});

adapter.onTurnError = async (context: TurnContext, error: Error) => {
    // Storage eTag conflicts can happen when multiple activities for the
    // same conversation are processed in parallel. The user-facing reply has
    // already been sent at this point; surface a "Sorry" message and we'd be
    // double-replying. Just log and bail.
    const msg = (error as Error)?.message ?? "";
    if (msg.includes("eTag conflict")) {
        console.warn("[onTurnError] swallowed eTag conflict on state save:", msg);
        return;
    }
    console.error("[onTurnError]", error);
    await context.sendTraceActivity(
        "OnTurnError Trace",
        `${error}`,
        "https://www.botframework.com/schemas/error",
        "TurnError"
    );
    await context.sendActivity("Sorry — something went wrong handling that message.");
};

const server = restify.createServer();
server.use(restify.plugins.bodyParser());

server.post("/api/messages", async (req, res) => {
    await adapter.process(req, res, async (context) => {
        await app.run(context);
    });
});

server.get("/health", (_req, res, next) => {
    res.send(200, { status: "ok" });
    next();
});

server.listen(config.port, () => {
    console.log(`Bot listening on http://localhost:${config.port}`);
    console.log("Messaging endpoint: POST /api/messages");
});

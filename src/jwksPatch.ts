// Workaround for a botframework-connector race / staleness bug.
//
// `OpenIdMetadata.getKey(kid)` only refreshes its JWKS cache at most once per
// hour when a key isn't found locally. Bot Framework Service load-balances
// signing across multiple signing services and rotates keys. If an incoming
// JWT's `kid` isn't in our cached JWKS, the SDK returns null and throws
// "Signing Key could not be retrieved" (HTTP 401), causing intermittent
// Web Chat / Direct Line failures.
//
// This patch removes the 1-hour throttle: whenever a kid lookup misses, we
// refresh the cache immediately and try again. The refresh is itself
// inexpensive (one HTTPS round-trip) and the SDK already serializes it via
// a single in-flight promise per instance.

import { ConnectorClient } from "botframework-connector";

// eslint-disable-next-line @typescript-eslint/no-var-requires
const openIdMetadataModule = require("botframework-connector/lib/auth/openIdMetadata");
type OpenIdMetadataCtor = new (...args: unknown[]) => {
    lastUpdated: number;
    getKey: (kid: string) => Promise<unknown>;
    refreshCache: () => Promise<void>;
};

export function patchJwksRefresh(): void {
    const cls = openIdMetadataModule.OpenIdMetadata as OpenIdMetadataCtor | undefined;
    if (!cls) {
        console.warn(
            "[jwksPatch] Could not locate OpenIdMetadata class on botframework-connector — skipping."
        );
        return;
    }
    const proto = cls.prototype as {
        getKey: (kid: string) => Promise<unknown>;
        refreshCache: () => Promise<void>;
        findKey: (kid: string) => unknown;
        lastUpdated: number;
        __patched?: boolean;
    };
    if (proto.__patched) return;

    proto.getKey = async function (kid: string) {
        let key = this.findKey(kid);
        if (!key) {
            try {
                await this.refreshCache();
                this.lastUpdated = Date.now();
                key = this.findKey(kid);
            } catch (err) {
                console.warn(`[jwksPatch] refreshCache failed for kid=${kid}:`, err);
            }
        }
        return key ?? null;
    };

    proto.__patched = true;
    // Touch ConnectorClient so the import is not tree-shaken.
    void ConnectorClient;
    console.log("[jwksPatch] OpenIdMetadata.getKey patched (refresh-on-miss).");
}

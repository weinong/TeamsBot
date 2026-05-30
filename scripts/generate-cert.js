const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const selfsigned = require("selfsigned");

// Days the cert is valid for. Entra app management policies typically cap
// credential lifetime at 90, 180, or 365 days. Override via --days=N or
// CERT_DAYS env var if your tenant policy is stricter or looser.
const argDays = (process.argv.find((a) => a.startsWith("--days=")) || "").split("=")[1];
const days = parseInt(argDays || process.env.CERT_DAYS || "180", 10);

const outDir = path.resolve(__dirname, "..", "certs");
fs.mkdirSync(outDir, { recursive: true });

const attrs = [{ name: "commonName", value: "TeamsFAQBot" }];
const pems = selfsigned.generate(attrs, {
    keySize: 2048,
    days,
    algorithm: "sha256",
    extensions: [
        { name: "basicConstraints", cA: false },
        { name: "keyUsage", digitalSignature: true, keyEncipherment: true },
        { name: "extKeyUsage", clientAuth: true },
    ],
});

const certPath = path.join(outDir, "bot.cer");
const keyPath = path.join(outDir, "bot.key");
fs.writeFileSync(certPath, pems.cert, { mode: 0o600 });
fs.writeFileSync(keyPath, pems.private, { mode: 0o600 });

const x509 = new crypto.X509Certificate(pems.cert);
const thumbprint = x509.fingerprint.replace(/:/g, "").toUpperCase();

console.log(`Cert        : ${certPath}`);
console.log(`Key         : ${keyPath}`);
console.log(`Subject     : ${x509.subject}`);
console.log(`Valid from  : ${x509.validFrom}`);
console.log(`Valid to    : ${x509.validTo}  (${days} days)`);
console.log(`SHA-1 thumb : ${thumbprint}`);

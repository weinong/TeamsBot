# Multi-stage build for the Teams FAQ bot.

FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --no-audit --no-fund
COPY tsconfig.json ./
COPY src ./src
COPY data ./data
RUN npm run build

FROM node:20-alpine AS runtime
ENV NODE_ENV=production
WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force

COPY --from=build /app/lib ./lib
COPY --from=build /app/data ./data

# Container Apps will set PORT. Default to 3978 for local docker runs.
ENV PORT=3978
EXPOSE 3978

USER node
CMD ["node", "lib/index.js"]

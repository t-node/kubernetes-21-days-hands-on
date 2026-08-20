# DevBoard frontend (React + Vite) -- COURSE BUILD.
#
# Same reason as backend.Dockerfile: upstream uses dhi.io/node, which most
# people cannot pull. This uses the public node image.
#
# HOW THIS CONTAINER SERVES THE APP -- read this, it matters all course:
#
#   `vite preview` serves the built SPA on :4173 AND acts as a reverse proxy.
#   vite.preview.config.js forwards  /api/*  ->  http://backend:8080/*
#   (the /api prefix is STRIPPED on the way through).
#
#   So the hostname `backend` is not decoration -- it is baked into this image.
#   In Kubernetes your backend Service MUST be named `backend` in the same
#   namespace, or you must override /app/vite.config.js from a ConfigMap.
#   That is the Day 09 exercise.
#
# Build context is app/devboard/frontend.

########################  build stage  ########################
FROM node:22-alpine AS build

WORKDIR /app

COPY package*.json ./
# --legacy-peer-deps matches upstream; the lockfile has peer conflicts
RUN npm ci --legacy-peer-deps

COPY . .
RUN npm run build

########################  runtime stage  ########################
FROM node:22-alpine

WORKDIR /app

COPY --from=build --chown=node:node /app/dist ./dist
COPY --from=build --chown=node:node /app/node_modules ./node_modules
# The preview config becomes THE config -- this is what proxies /api.
COPY --from=build --chown=node:node /app/vite.preview.config.js ./vite.config.js

USER node

EXPOSE 4173

CMD ["./node_modules/.bin/vite", "preview", "--host", "0.0.0.0", "--port", "4173"]

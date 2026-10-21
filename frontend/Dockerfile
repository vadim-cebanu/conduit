# Image versions (build arguments with default values)
ARG NODE_VERSION=20.18
ARG NGINX_VERSION=1.27

# ---------- Stage 1: build the Angular app ----------
FROM node:${NODE_VERSION}-alpine AS build

# skip the husky git hooks (there is no .git folder in the image)
ENV HUSKY=0

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build

# ---------- Stage 2: serve the static files with nginx ----------
FROM nginx:${NGINX_VERSION}-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist/angular-conduit /usr/share/nginx/html

EXPOSE 80
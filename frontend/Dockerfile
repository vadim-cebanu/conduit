# ---------- Stage 1: build the Angular app ----------
FROM node:20.18-alpine AS build

# skip the husky git hooks (there is no .git folder in the image)
ENV HUSKY=0

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build

# ---------- Stage 2: serve the static files with nginx ----------
FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist/angular-conduit /usr/share/nginx/html

EXPOSE 80
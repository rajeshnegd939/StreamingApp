# ---- build the React app ----
FROM node:20-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci

COPY . .

# Relative URLs: the browser calls the same host it loaded the page from,
# and nginx in this image forwards /api/* to the right backend service.
ARG REACT_APP_AUTH_API_URL=/api
ARG REACT_APP_STREAMING_API_URL=/api
ARG REACT_APP_STREAMING_PUBLIC_URL=/
ARG REACT_APP_ADMIN_API_URL=/api/admin
ARG REACT_APP_CHAT_API_URL=/api/chat
ARG REACT_APP_CHAT_SOCKET_URL=/
ENV REACT_APP_AUTH_API_URL=$REACT_APP_AUTH_API_URL \
    REACT_APP_STREAMING_API_URL=$REACT_APP_STREAMING_API_URL \
    REACT_APP_STREAMING_PUBLIC_URL=$REACT_APP_STREAMING_PUBLIC_URL \
    REACT_APP_ADMIN_API_URL=$REACT_APP_ADMIN_API_URL \
    REACT_APP_CHAT_API_URL=$REACT_APP_CHAT_API_URL \
    REACT_APP_CHAT_SOCKET_URL=$REACT_APP_CHAT_SOCKET_URL

RUN npm run build

# ---- serve with nginx (runs as non-root, listens on 8080) ----
FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /app/build /usr/share/nginx/html

# backend service addresses, overridden by the Helm chart
ENV DNS_RESOLVER=kube-dns.kube-system.svc.cluster.local \
    AUTH_SERVICE=auth:3001 \
    STREAMING_SERVICE=streaming:3002 \
    ADMIN_SERVICE=admin:3003 \
    CHAT_SERVICE=chat:3004
EXPOSE 8080

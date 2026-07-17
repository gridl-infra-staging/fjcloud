# ---------------------------------------------------------------------------
# Griddle Web — SvelteKit Docker build
# ---------------------------------------------------------------------------
# Build:  docker build -t griddle-web ./web
# Run:    docker run -p 5173:5173 --env-file .env.local griddle-web

FROM node:20-slim

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .

EXPOSE 5173

CMD ["npm", "run", "dev", "--", "--host", "0.0.0.0"]

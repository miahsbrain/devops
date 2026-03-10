# =============================================================================
# Service 3: Inventory Cloud Run
# Lightweight Node.js image deployed to Cloud Run
# Cloud Run default port is 8080
# =============================================================================
FROM node:20-alpine

WORKDIR /app

COPY package*.json ./
RUN npm install --production

COPY . .

EXPOSE 8080

CMD ["node", "index.js"]

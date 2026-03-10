# =============================================================================
# Service 4: Payments API
# Lightweight Node.js image served from GKE
# =============================================================================
FROM node:20-alpine

WORKDIR /app

COPY package*.json ./
RUN npm install --production

COPY . .

EXPOSE 3002

CMD ["node", "index.js"]

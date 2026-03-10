FROM node:20-alpine

WORKDIR /app

# Copy dependency files first — Docker caches this layer
# so npm install only re-runs when package.json changes
COPY package*.json ./
RUN npm install --omit=dev
# RUN npm ci --only=production

# Copy source code
COPY . .

EXPOSE 8080

# Run as non-root user for security
USER node

CMD ["node", "index.js"]

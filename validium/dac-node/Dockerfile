FROM node:22-alpine

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci --production=false

COPY tsconfig.json ./
COPY proto/ ./proto/
COPY src/ ./src/

RUN npm run build

ENV DAC_HOST=0.0.0.0
ENV DAC_PORT=50051
ENV DAC_DATA_DIR=/data

VOLUME ["/data"]

EXPOSE 50051

CMD ["node", "dist/index.js"]

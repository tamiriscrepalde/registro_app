FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
# CA da AWS para TLS verificado com o RDS; legível pelo usuário node
RUN mkdir -p /app/certs \
  && wget -qO /app/certs/rds-global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
  && chmod 755 /app/certs && chmod 644 /app/certs/rds-global-bundle.pem
COPY src ./src
COPY migrations ./migrations
USER node
EXPOSE 3000
CMD ["node", "src/index.js"]

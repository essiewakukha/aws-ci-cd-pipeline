FROM public.ecr.aws/docker/library/node:18-slim

WORKDIR /usr/src/app

COPY package*.json ./
RUN npm install --omit=dev

COPY src ./src

EXPOSE 3000
CMD ["node", "src/app.js"]

FROM node:alpine

RUN apk add --no-cache tini git \
    && yarn global add git-http-server \
    && adduser -D -g git git

WORKDIR /home/git/applications.git

COPY --chown=1000:100 applications  /home/git/applications.git/applications

ENV GIT_USER="blairdrummond"
ENV GIT_EMAIL="blair.drummond@canada.ca"

RUN find . -name .gitignore -delete \
    && git config --global user.email "$GIT_EMAIL" \
    && git config --global user.namel "$GIT_NAME" \
    && git init \
    && git add . \
    && git commit -m 'ArgoCD Shipwright KIND' \
    && chown -R git .

USER git

EXPOSE 8080
ENTRYPOINT ["tini", "--", "git-http-server", "-p", "8080", "/home/git"]

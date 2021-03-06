#!/bin/bash
# Michael O'Brien : michael at obrienlabs.org
# 2017/2018
# ported to https://gerrit.onap.org/r/#/c/32019
# This installation is for a rancher managed install of kubernetes
# after this run the standard oom install
# this installation can be run on amy ubuntu 16.04 VM or physical host
# https://wiki.onap.org/display/DW/ONAP+on+Kubernetes
# Amsterdam
#     Rancher 1.6.10, Kubernetes 1.7.7, Kubectl 1.7.7, Helm 2.3.0, Docker 1.12
# master
#     Rancher 1.6.14, Kubernetes 1.8.6, Kubectl 1.8.6, Helm 2.6.1, Docker 17.03
# run as root - because of the logout that would be required after the docker user set

usage() {
cat <<EOF
Usage: $0 [PARAMs]
-u                  : Display usage
-b [branch]         : branch = master or amsterdam (required)
-s [server]         : server = IP or DNS name (required)
-e [environment]    : use the default (onap)
EOF
}

install_onap() {

  if [ "$BRANCH" == "amsterdam" ]; then
    RANCHER_VERSION=1.6.10
    KUBECTL_VERSION=1.7.7
    HELM_VERSION=2.3.0
    DOCKER_VERSION=1.12
  else
    RANCHER_VERSION=1.6.14
    KUBECTL_VERSION=1.8.6
    HELM_VERSION=2.6.1
    DOCKER_VERSION=17.03
  fi

  echo "Installing on ${SERVER} for ${BRANCH}: Rancher: ${RANCHER_VERSION} Kubectl: ${KUBECTL_VERSION} Helm: ${HELM_VERSION} Docker: ${DOCKER_VERSION}"
  echo "127.0.0.1 ${SERVER}" >> /etc/hosts

  curl https://releases.rancher.com/install-docker/$DOCKER_VERSION.sh | sh
  # when running as non-root (ubuntu) run the following and logout/log back in
  #sudo usermod -aG docker ubuntu
  docker run -d --restart=unless-stopped -p 8880:8080 --name rancher_server rancher/server:v$RANCHER_VERSION
  curl -LO https://storage.googleapis.com/kubernetes-release/release/v$KUBECTL_VERSION/bin/linux/amd64/kubectl
  chmod +x ./kubectl
  sudo mv ./kubectl /usr/local/bin/kubectl
  mkdir ~/.kube
  wget http://storage.googleapis.com/kubernetes-helm/helm-v${HELM_VERSION}-linux-amd64.tar.gz
  tar -zxvf helm-v${HELM_VERSION}-linux-amd64.tar.gz
  sudo mv linux-amd64/helm /usr/local/bin/helm

  # create kubernetes environment on rancher using cli
  RANCHER_CLI_VER=0.6.7
  KUBE_ENV_NAME=$ENVIRON
  wget https://releases.rancher.com/cli/v${RANCHER_CLI_VER}/rancher-linux-amd64-v${RANCHER_CLI_VER}.tar.gz
  tar -zxvf rancher-linux-amd64-v${RANCHER_CLI_VER}.tar.gz
  cp rancher-v${RANCHER_CLI_VER}/rancher .
  chmod +x ./rancher

  apt install jq -y
  sleep 60
  API_RESPONSE=`curl -s 'http://127.0.0.1:8880/v2-beta/apikey' -d '{"type":"apikey","accountId":"1a1","name":"autoinstall","description":"autoinstall","created":null,"kind":null,"removeTime":null,"removed":null,"uuid":null}'`
  # Extract and store token
  echo "API_RESPONSE: $API_RESPONSE"
  KEY_PUBLIC=`echo $API_RESPONSE | jq -r .publicValue`
  KEY_SECRET=`echo $API_RESPONSE | jq -r .secretValue`
  echo "publicValue: $KEY_PUBLIC secretValue: $KEY_SECRET"

  export RANCHER_URL=http://${SERVER}:8880
  export RANCHER_ACCESS_KEY=$KEY_PUBLIC
  export RANCHER_SECRET_KEY=$KEY_SECRET
  ./rancher env ls
  echo "Creating kubernetes environment named ${KUBE_ENV_NAME}"
  ./rancher env create -t kubernetes $KUBE_ENV_NAME > kube_env_id.json
  PROJECT_ID=$(<kube_env_id.json)
  echo "env id: $PROJECT_ID"
  export RANCHER_HOST_URL=http://${SERVER}:8880/v1/projects/$PROJECT_ID
  echo "you should see an additional kubernetes environment"
  ./rancher env ls
  # optionally disable cattle env

  # add host registration url
  # https://github.com/rancher/rancher/issues/2599
  REG_URL_RESPONSE=`curl -X POST -u $KEY_PUBLIC:$KEY_SECRET -H 'Accept: application/json' -H 'ContentType: application/json' -d '{"name":"$SERVER"}' "http://$SERVER:8880/v1/projects/$PROJECT_ID/registrationtokens"`
  echo "REG_URL_RESPONSE: $REG_URL_RESPONSE"
  echo "wait for server to finish url configuration - 1 min"
  sleep 60
  # see registrationUrl in
  REGISTRATION_TOKENS=`curl http://127.0.0.1:8880/v2-beta/registrationtokens`
  echo "REGISTRATION_TOKENS: $REGISTRATION_TOKENS"
  REGISTRATION_URL=`echo $REGISTRATION_TOKENS | jq -r .data[0].registrationUrl`
  REGISTRATION_DOCKER=`echo $REGISTRATION_TOKENS | jq -r .data[0].image`
  REGISTRATION_TOKEN=`echo $REGISTRATION_TOKENS | jq -r .data[0].token`
  echo "Registering host for image: $REGISTRATION_DOCKER url: $REGISTRATION_URL registrationToken: $REGISTRATION_TOKEN"
  HOST_REG_COMMAND=`echo $REGISTRATION_TOKENS | jq -r .data[0].command`
  docker run --rm --privileged -v /var/run/docker.sock:/var/run/docker.sock -v /var/lib/racher:/var/lib/rancher $REGISTRATION_DOCKER $RANCHER_URL/v1/scripts/$REGISTRATION_TOKEN
  echo "waiting 7 min for host registration to finish"
  sleep 420
  #read -p "wait for host registration to complete before generating the client token....."

  # base64 encode the kubectl token from the auth pair
  # generate this after the host is registered
  KUBECTL_TOKEN=$(echo -n 'Basic '$(echo -n "$RANCHER_ACCESS_KEY:$RANCHER_SECRET_KEY" | base64 -w 0) | base64 -w 0)
  echo "KUBECTL_TOKEN base64 encoded: ${KUBECTL_TOKEN}"
  # add kubectl config - NOTE: the following spacing has to be "exact" or kubectl will not connect - with a localhost:8080 error
  cat > ~/.kube/config <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    api-version: v1
    insecure-skip-tls-verify: true
    server: "https://$SERVER:8880/r/projects/$PROJECT_ID/kubernetes:6443"
  name: "${ENVIRON}"
contexts:
- context:
    cluster: "${ENVIRON}"
    user: "${ENVIRON}"
  name: "${ENVIRON}"
current-context: "${ENVIRON}"
users:
- name: "${ENVIRON}"
  user:
    token: "$KUBECTL_TOKEN"

EOF

  echo "run the following if you installed a higher kubectl version than the server"
  echo "helm init --upgrade"
  echo "Verify all pods up on the kubernetes system - will return localhost:8080 until a host is added"
  echo "kubectl get pods --all-namespaces"
  kubectl get pods --all-namespaces
}

BRANCH=
SERVER=

while getopts ":b:s:e:u:" PARAM; do
  case $PARAM in
    u)
      usage
      exit 1
      ;;
    b)
      BRANCH=${OPTARG}
      ;;
    e)
      ENVIRON=${OPTARG}
      ;;
    s)
      SERVER=${OPTARG}
      ;;
    ?)
      usage
      exit
      ;;
    esac
done

if [[ -z $BRANCH ]]; then
  usage
  exit 1
fi

install_onap $BRANCH $SERVER $ENVIRON


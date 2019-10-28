#!/usr/bin/env bash
# k8saposetup.sh - configure Kubernetes to work with aporeto

APORETO_RELEASE=${APORETO_RELEASE:-"release-3.11.15"}
CLUSTER_NAME=${CLUSTER_NAME:-"mycluster1"}
DEFAULT_API_URL="https://api.console.aporeto.com"
USE_TILLER=${USE_TILLER:-true}
PLATFORM=$(uname | tr '[:upper:]' '[:lower:]')

aporeto_bin_url="https://download.aporeto.com/releases/${APORETO_RELEASE}/apoctl/${PLATFORM}/apoctl"
aporeto_helm_url="https://charts.aporeto.com/releases/${APORETO_RELEASE}/clients"

check_prereqs() {
  local quit=false
  echo "> Checking prerequisites"
  for p in yq curl kubectl helm; do
    if ! command -v ${p}; then
      echo >&2 "Please install ${p}"
      quit=true
    fi
  done
  if ! kubectl cluster-info ; then
    echo >&2 "Please configure kubectl for your Kubernetes cluster"
    quit=true
  fi
  [ ${quit} = true ] && exit 1
  if ! command -v apoctl ; then
    echo >&2 "Could not find apoctl"
    install_apoctl
  fi
  kver_min=$(kubectl version -o yaml | yq r - serverVersion.minor)
  kver_maj=$(kubectl version -o yaml | yq r - serverVersion.major)
  if ((kver_maj != 1 || kver_min < 11)); then
    echo "Unsupported version of Kubernetes ${kver_maj}.${kver_min}"
    exit 1
  fi

}

install_apoctl () {
  echo "> Installing apoctl"
  echo "You might be asked for your supeuser password in order to place "
  echo "the apoctl executable in /usr/local/bin"
  curl -sSL ${aporeto_bin_url} -o apoctl
  chmod +x apoctl
  sudo mv apoctl /usr/local/bin/
}

authenticate () {
  echo "Please enter your Aporeto credentials:"
  echo
  echo -n "Aporeto account name: "
  read -r APORETO_ACCOUNT
  echo -n "Aporeto account password: "
  read -r -s APORETO_PASSWORD
  echo
  echo "Working ..."

  ## auth
  eval "$(apoctl auth aporeto --account "${APORETO_ACCOUNT}" --password "${APORETO_PASSWORD}" --validity 1h -e)"
}

create_namespace () {
  echo "> Creating namespace /${APORETO_ACCOUNT}/${CLUSTER_NAME}"
  if [[ "$(apoctl api count ns -n "/${APORETO_ACCOUNT}" --filter "name == /${APORETO_ACCOUNT}/${CLUSTER_NAME}")" == "0" ]]; then
      apoctl api create ns -n "/${APORETO_ACCOUNT}" -k name "${CLUSTER_NAME}" || exit 1
  fi
  export APOCTL_NAMESPACE="/${APORETO_ACCOUNT}/${CLUSTER_NAME}"
}

obtain_admin_appcred () {
  echo "> Getting namespace editor app credentials for /${APORETO_ACCOUNT}/${CLUSTER_NAME}"
  [ -d ~/.apoctl ] && rm -rf ~/.apoctl
  mkdir ~/.apoctl
  apoctl appcred create administrator-credentials --role @auth:role=namespace.editor -n "/${APORETO_ACCOUNT}/${CLUSTER_NAME}" > ~/.apoctl/creds.json
  chmod 400 ~/.apoctl/creds.json
  cat << EOF > ~/.apoctl/default.yaml
api: ${DEFAULT_API_URL}
namespace: /${APORETO_ACCOUNT}/${CLUSTER_NAME}
creds: ~/.apoctl/creds.json
EOF
  apoctl auth verify
}

create_tiller () {
  cat << EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tiller
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tiller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: tiller
    namespace: kube-system
EOF
}

create_enforcer_profile () {
  cat <<'EOF' | apoctl api import -f -
label: kubernetes-default-enforcerprofile
data:
  enforcerprofiles:
  - name: kubernetes-default
    metadata:
    - '@profile:name=kubernetes-default'
    description: Default Profile for Kubernetes
    excludedNetworks:
    - 127.0.0.0/8
    ignoreExpression:
    - - '@app:k8s:namespace=aporeto'
    - - '@app:k8s:namespace=aporeto-operator'
    - - '@app:k8s:namespace=kube-system'
    excludedInterfaces: []
    targetNetworks: []
    targetUDPNetworks: []
  enforcerprofilemappingpolicies:
  - name: fallback-kubernetes-default
    fallback: true
    description: "Kubernetes fallback: if there is no other profile, use the default Kubernetes profile."
    object:
    - - '@profile:name=kubernetes-default'
    subject:
    - - $identity=enforcer
EOF
}

create_automation_all_connections () {
  cat <<'EOF' | apoctl api import -f -
label: install-default-allow-all-policies
data:
  automations:
  - name: install-default-allow-all-policies
    description: Installs default allow all fallback policies for every child namespace that gets created to mimic Kubernetes default behavior.
    trigger: Event
    events:
      namespace:
      - create
    entitlements:
      externalnetwork:
      - create
      networkaccesspolicy:
      - create
    condition: |-
      function when(api, params) {
          return { continue: true, payload: { namespace: params.eventPayload.entity } };
      }
    actions:
    - |-
      function then(api, params, payload) {
          api.Create('externalnetwork', {
              name: 'external-tcp-all',
              description: 'Created by an automation on namespace creation. It is safe to be deleted, if not required.',
              metadata: ['@ext:name=tcpall'],
              entries: ['0.0.0.0/0'],
              ports: ['1:65535'],
              protocols: ['tcp'],
              propagate: true,
          }, payload.namespace.name);
          api.Create('externalnetwork', {
              name: 'external-udp-all',
              description: 'Created by an automation on namespace creation. It is safe to be deleted, if not required.',
              metadata: ['@ext:name=udpall'],
              entries: ['0.0.0.0/0'],
              ports: ['1:65535'],
              protocols: ['udp'],
              propagate: true,
          }, payload.namespace.name);
          api.Create('networkaccesspolicy', {
              name: 'default-fallback-ingress-allow-all',
              description: 'Created by an automation on namespace creation. It is safe to be deleted, if not required.',
              metadata: ['@netpol=default-fallback'],
              propagate: true,
              fallback: true,
              logsEnabled: true,
              observationEnabled: true,
              observedTrafficAction: 'Apply',
              action: 'Allow',
              applyPolicyMode: 'IncomingTraffic',
              subject: [
                  ['$identity=processingunit'],
                  ['@ext:name=tcpall'],
                  ['@ext:name=udpall'],
              ],
              object: [['$namespace='+payload.namespace.name]],
          }, payload.namespace.name);
          api.Create('networkaccesspolicy', {
              name: 'default-fallback-egress-allow-all',
              description: 'Created by an automation on namespace creation. It is safe to be deleted, if not required',
              metadata: ['@netpol=default-fallback'],
              propagate: true,
              fallback: true,
              logsEnabled: true,
              observationEnabled: true,
              observedTrafficAction: 'Apply',
              action: 'Allow',
              applyPolicyMode: 'OutgoingTraffic',
              subject: [['$namespace='+payload.namespace.name]],
              object: [
                  ['$identity=processingunit'],
                  ['@ext:name=tcpall'],
                  ['@ext:name=udpall'],
              ],
          }, payload.namespace.name);
      }
EOF
}

prepare_k8s () {
  echo "> Creating enforcer profile in Aporeto that will ignore loopback traffic, allowing sidecar containers to communicate with each other"
  create_enforcer_profile

  echo "> Create an automation in Aporeto that will allow all traffic at first"
  create_automation_all_connections

  echo "> Creating Kubernetes namespaces and credentials for Aporeto's tooling"
  kubectl create namespace aporeto-operator
  kubectl create namespace aporeto
  apoctl appcred create enforcerd --type k8s --role "@auth:role=enforcer" | kubectl apply -f - -n aporeto
  apoctl appcred create aporeto-operator --type k8s --role "@auth:role=aporeto-operator" | kubectl apply -f - -n aporeto-operator

  echo "> Making sure the credentials are stored in Kubernetes"
  kubectl -n aporeto-operator get secrets | grep Opaque
  kubectl -n aporeto get secrets | grep Opaque

  if [ ${USE_TILLER} = true ]; then
    echo "> Creating tiller account and initializing helm"
    create_tiller
    helm init --service-account tiller --upgrade --wait

    echo "> Adding Aporeto's helm repository"
    helm repo add aporeto ${aporeto_helm_url}

    echo "> Deploying the Aporeto Operator"
    helm install aporeto/aporeto-crds --name aporeto-crds --wait
    helm install aporeto/aporeto-operator --name aporeto-operator --namespace aporeto-operator --wait
    kubectl get pods -n aporeto-operator

    echo "> Installing the enforcer and verifying it"
    helm install aporeto/enforcerd --name enforcerd --namespace aporeto --wait
  else
    echo "Initializing client only mode for helm"
    helm init --client-only --upgrade --wait

    echo "> Adding Aporeto's helm repository"
    helm repo add aporeto ${aporeto_helm_url}
    for d in charts values manifests; do
      [ -d ${d} ] && rm -rf ${d}
      mkdir ${d}
    done
    # Fetch charts
    helm fetch --untar --untardir charts/ aporeto/aporeto-crds
    helm fetch --untar --untardir charts/ aporeto/aporeto-operator
    helm fetch --untar --untardir charts/ aporeto/enforcerd
    cp charts/aporeto-operator/values.yaml values/aporeto-operator.yaml
    cp charts/enforcerd/values.yaml values/enforcerd.yaml
    # Render charts
    helm template  --output-dir manifests/ --name aporeto-crds --namespace default charts/aporeto-crds
    helm template  --output-dir manifests/ --name aporeto-operator --namespace aporeto-operator charts/aporeto-operator
    helm template  --output-dir manifests/ --name enforcerd --namespace aporeto charts/enforcerd
    # Kubernetes 1.16 graduated DS API from beta to stable
    if ((kver_min > 15)); then
      local ds="manifests/enforcerd/templates/ds.yaml"
      if [ $(yq r ${ds} apiVersion) = "extensions/v1beta1" ]; then
        echo "Adjusting manifests for Kubernetes ${kver_maj}.${kver_min}"
        yq w -i ${ds} apiVersion apps/v1
        yq w -i ${ds} spec.selector.matchLabels.app enforcerd
        yq w -i ${ds} spec.selector.matchLabels.type aporeto
      fi
    fi

    # Apply rendered charts
    kubectl apply --recursive -f manifests/aporeto-crds
    kubectl get -n default crds
    kubectl apply --namespace aporeto-operator -f manifests/aporeto-operator/templates/pre-install.yaml
    for m in deployment rbac post-delete; do
      kubectl apply --namespace aporeto-operator -f manifests/aporeto-operator/templates/${m}.yaml
    done
    #kubectl wait -f manifests/aporeto-operator/templates/deployment.yaml --for condition=available
    kubectl apply --namespace aporeto --recursive -f manifests/enforcerd
    kubectl wait -f manifests/enforcerd/templates/ds.yaml --for condition=available
  fi
  kubectl get pods --all-namespaces | grep aporeto
  apoctl api list enforcers --namespace ${APOCTL_NAMESPACE} -c ID -c name -c namespace -c operationalStatus
}

# Main
check_prereqs
authenticate
create_namespace
obtain_admin_appcred
prepare_k8s
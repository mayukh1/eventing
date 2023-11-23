#!/usr/bin/env bash

if [[ -n "${ARTIFACT_DIR:-}" ]]; then
  BUILD_NUMBER=${BUILD_NUMBER:-$(head -c 128 < /dev/urandom | base64 | fold -w 8 | head -n 1)}
  ARTIFACTS="${ARTIFACT_DIR}/build-${BUILD_NUMBER}"
  export ARTIFACTS
  mkdir -p "${ARTIFACTS}"
fi

export EVENTING_NAMESPACE="${EVENTING_NAMESPACE:-knative-eventing}"
export SYSTEM_NAMESPACE=$EVENTING_NAMESPACE
export ZIPKIN_NAMESPACE=$EVENTING_NAMESPACE
export KNATIVE_DEFAULT_NAMESPACE=$EVENTING_NAMESPACE
export CONFIG_TRACING_CONFIG="test/config/config-tracing.yaml"
export EVENTING_TEST_IMAGE_TEMPLATE=$(cat <<-END
{{- with .Name }}
{{- if eq . "event-flaker"}}$KNATIVE_EVENTING_TEST_EVENT_FLAKER{{end -}}
{{- if eq . "event-library"}}$KNATIVE_EVENTING_TEST_EVENT_LIBRARY{{end -}}
{{- if eq . "event-sender"}}$KNATIVE_EVENTING_TEST_EVENT_SENDER{{end -}}
{{- if eq . "eventshub"}}$KNATIVE_EVENTING_TEST_EVENTSHUB{{end -}}
{{- if eq . "heartbeats"}}$KNATIVE_EVENTING_TEST_HEARTBEATS{{end -}}
{{- if eq . "performance"}}$KNATIVE_EVENTING_TEST_PERFORMANCE{{end -}}
{{- if eq . "print"}}$KNATIVE_EVENTING_TEST_PRINT{{end -}}
{{- if eq . "recordevents"}}$KNATIVE_EVENTING_TEST_RECORDEVENTS{{end -}}
{{- if eq . "request-sender"}}$KNATIVE_EVENTING_TEST_REQUEST_SENDER{{end -}}
{{- if eq . "wathola-fetcher"}}$KNATIVE_EVENTING_TEST_WATHOLA_FETCHER{{end -}}
{{- if eq . "wathola-forwarder"}}$KNATIVE_EVENTING_TEST_WATHOLA_FORWARDER{{end -}}
{{- if eq . "wathola-receiver"}}$KNATIVE_EVENTING_TEST_WATHOLA_RECEIVER{{end -}}
{{- if eq . "wathola-sender"}}$KNATIVE_EVENTING_TEST_WATHOLA_SENDER{{end -}}
{{end -}}
END
)

function scale_up_workers(){
  local cluster_api_ns="openshift-machine-api"

  oc get machineset -n ${cluster_api_ns} --show-labels

  # Get the name of the first machineset that has at least 1 replica
  local machineset
  machineset=$(oc get machineset -n ${cluster_api_ns} -o custom-columns="name:{.metadata.name},replicas:{.spec.replicas}" | grep " 1" | head -n 1 | awk '{print $1}')
  # Bump the number of replicas to 6 (+ 1 + 1 == 8 workers)
  oc patch machineset -n ${cluster_api_ns} "${machineset}" -p '{"spec":{"replicas":6}}' --type=merge
  wait_until_machineset_scales_up ${cluster_api_ns} "${machineset}" 6
}

# Waits until the machineset in the given namespaces scales up to the
# desired number of replicas
# Parameters: $1 - namespace
#             $2 - machineset name
#             $3 - desired number of replicas
function wait_until_machineset_scales_up() {
  echo -n "Waiting until machineset $2 in namespace $1 scales up to $3 replicas"
  for _ in {1..150}; do  # timeout after 15 minutes
    local available
    available=$(oc get machineset -n "$1" "$2" -o jsonpath="{.status.availableReplicas}")
    if [[ ${available} -eq $3 ]]; then
      echo -e "\nMachineSet $2 in namespace $1 successfully scaled up to $3 replicas"
      return 0
    fi
    echo -n "."
    sleep 6
  done
  echo - "Error: timeout waiting for machineset $2 in namespace $1 to scale up to $3 replicas"
  return 1
}

# Loops until duration (car) is exceeded or command (cdr) returns non-zero
function timeout_non_zero() {
  SECONDS=0; TIMEOUT=$1; shift
  while eval $*; do
    sleep 5
    [[ $SECONDS -gt $TIMEOUT ]] && echo "ERROR: Timed out" && return 1
  done
  return 0
}

function install_serverless(){
  header "Installing Serverless Operator"

  KNATIVE_EVENTING_MANIFESTS_DIR="$(pwd)/openshift/release/artifacts"
  export KNATIVE_EVENTING_MANIFESTS_DIR

  local operator_dir=/tmp/serverless-operator
  git clone --branch release-1.31 https://github.com/openshift-knative/serverless-operator.git $operator_dir
  export GOPATH=/tmp/go
  local failed=0
  pushd $operator_dir || return $?
  export ON_CLUSTER_BUILDS=true
  export DOCKER_REPO_OVERRIDE=image-registry.openshift-image-registry.svc:5000/openshift-marketplace
  OPENSHIFT_CI="true" TRACING_BACKEND="zipkin" ENABLE_TRACING="true" make generated-files images install-tracing install-eventing || failed=$?
  cat ${operator_dir}/olm-catalog/serverless-operator/manifests/serverless-operator.clusterserviceversion.yaml
  popd || return $?

  return $failed
}

function run_e2e_rekt_tests(){
  header "Running E2E Reconciler Tests"
  HW_ARCH=$(arch)
  
  images_file=$(dirname $(realpath "$0"))/images.yaml
  #skipping for P/Z as the test images aren't multiarch.
  if [ $HW_ARCH != "ppc64le" ] && [ $HW_ARCH != "s390x" ]; then
    echo -n "Mayukh"
    make generate-release
  fi
  cat "${images_file}"

  local test_name="${1:-}"
  local run_command=""
  local failed=0
 
  if [ -n "$test_name" ]; then
      local run_command="-run ^(${test_name})$"
  fi
  # check for test flags
  RUN_FLAGS="-timeout=1h -parallel=20"
  if [ -n "${EVENTING_TEST_FLAGS:-}" ]; then
    RUN_FLAGS="${EVENTING_TEST_FLAGS}"
  fi
  go_test_e2e ${RUN_FLAGS} ./test/rekt --images.producer.file="${images_file}" || failed=$?

  # Wait for all test namespaces to be deleted.
  timeout_non_zero 300 '[[ $(oc get project | grep -c test-) -gt 0 ]]' || return 1

  return $failed
}

function run_e2e_tests(){
  header "Running E2E tests with Multi Tenant Channel Based Broker"
  local test_name="${1:-}"
  local run_command=""
  local failed=0
  local channels=messaging.knative.dev/v1:Channel,messaging.knative.dev/v1:InMemoryChannel
  local sources=sources.knative.dev/v1beta2:PingSource,sources.knative.dev/v1:ApiServerSource,sources.knative.dev/v1:ContainerSource

  local common_opts=" -channels=$channels -sources=$sources --kubeconfig $KUBECONFIG"
  if [ -n "$test_name" ]; then
      local run_command="-run ^(${test_name})$"
  fi

  # check for test flags
  RUN_FLAGS="-timeout=50m -parallel=20"
  if [ -n "${EVENTING_TEST_FLAGS:-}" ]; then
    RUN_FLAGS="${EVENTING_TEST_FLAGS}"
  fi

  # check for test args
  if [ -n "${EVENTING_TEST_ARGS:-}" ]; then
    common_opts="${EVENTING_TEST_ARGS}"
  fi

  # execute tests
  go_test_e2e ${RUN_FLAGS} ./test/e2e \
    "$run_command" \
    -imagetemplate="$TEST_IMAGE_TEMPLATE" \
    ${common_opts} || failed=$?

  return $failed
}

function run_conformance_tests(){
  header "Running Conformance tests with Multi Tenant Channel Based Broker"
  local test_name="${1:-}"
  local run_command=""
  local failed=0
  local channels=messaging.knative.dev/v1:Channel,messaging.knative.dev/v1:InMemoryChannel
  local sources=sources.knative.dev/v1beta2:PingSource,sources.knative.dev/v1:ApiServerSource,sources.knative.dev/v1:ContainerSource

  local common_opts=" -channels=$channels -sources=$sources --kubeconfig $KUBECONFIG"
  if [ -n "$test_name" ]; then
      local run_command="-run ^(${test_name})$"
  fi

  # check for test flags
  RUN_FLAGS="-timeout=50m -parallel=12"
  if [ -n "${EVENTING_TEST_FLAGS:-}" ]; then
    RUN_FLAGS="${EVENTING_TEST_FLAGS}"
  fi

  # check for test args
  if [ -n "${EVENTING_TEST_ARGS:-}" ]; then
    common_opts="${EVENTING_TEST_ARGS}"
  fi

  # execute tests
  go_test_e2e ${RUN_FLAGS} ./test/conformance \
    "$run_command" \
    -imagetemplate="$TEST_IMAGE_TEMPLATE" \
    ${common_opts} || failed=$?

  return $failed
}

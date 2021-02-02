#!/bin/bash
source "$(dirname "${BASH_SOURCE}")/../../hack/lib/init.sh"
trap os::test::junit::reconcile_output EXIT

# Cleanup cluster resources created by this test
(
  set +e
  oc delete all,templates --all
  exit 0
) &>/dev/null

project="$(oc project -q)"
idled_at_annotation='idling.alpha.openshift.io/idled-at'
unidle_target_annotation='idling.alpha.openshift.io/unidle-targets'
prev_scale_annotation='idling.alpha.openshift.io/previous-scale'
idled_at_template="{{index .metadata.annotations \"${idled_at_annotation}\"}}"
unidle_target_template="{{index .metadata.annotations \"${unidle_target_annotation}\"}}"
prev_scale_template="{{index .metadata.annotations \"${prev_scale_annotation}\"}}"
dc_name=""

setup_idling_resources() {
    os::cmd::expect_success 'oc delete all --all'

    # set up resources for the idle command
    os::cmd::expect_success 'oc create -f ${TEST_DATA}/idling-svc-route.yaml'
    dc_name=$(basename $(oc create -f ${TEST_DATA}/idling-dc.yaml -o name))  # `basename type/name` --> name
    os::cmd::expect_success "oc describe deploymentconfigs '${dc_name}'"
    os::cmd::try_until_success 'oc describe endpoints idling-echo'

    # deployer pod won't work, so just scale up the rc ourselves
    os::cmd::try_until_success "oc get replicationcontroller ${dc_name}-1"
    os::cmd::expect_success "oc scale replicationcontroller ${dc_name}-1 --replicas=2"
    os::cmd::try_until_text "oc get pod -l app=idling-echo -o go-template='{{ len .items }}'" "2"

    # wait for endpoints to populate. Ensure subset exists first to avoid nil dereference.
    os::cmd::try_until_success "oc get endpoints idling-echo -o go-template='{{ index .subsets 0 }}'"
    os::cmd::try_until_text "oc get endpoints idling-echo -o go-template='{{ len (index .subsets 0).addresses }}'" "2"
}

os::test::junit::declare_suite_start "cmd/idle/by-name"
setup_idling_resources
os::cmd::expect_failure "oc idle dc/${dc_name}" # make sure manually passing non-endpoints resources fails
os::cmd::expect_success_and_text 'oc idle idling-echo' "The service will unidle DeploymentConfig \"${project}/${dc_name}\" to 2 replicas once it receives traffic"
os::cmd::expect_success_and_text "oc get endpoints idling-echo -o go-template='${idled_at_template}'" '.'
#os::cmd::expect_success_and_text "oc get endpoints idling-echo -o go-template='${unidle_target_template}' | jq '.[] | select(.name == \"${dc_name}\") | (.replicas == 2 and .kind == \"DeploymentConfig\")'" 'true'
os::test::junit::declare_suite_end

os::test::junit::declare_suite_start "cmd/idle/by-label"
setup_idling_resources
os::cmd::expect_success_and_text 'oc idle -l app=idling-echo' "The service will unidle DeploymentConfig \"${project}/${dc_name}\" to 2 replicas once it receives traffic"
os::cmd::expect_success_and_text "oc get endpoints idling-echo -o go-template='${idled_at_template}'" '.'
#os::cmd::expect_success_and_text "oc get endpoints idling-echo -o go-template='${unidle_target_template}' | jq '.[] | select(.name == \"${dc_name}\") | (.replicas == 2 and .kind == \"DeploymentConfig\")'" 'true'
os::test::junit::declare_suite_end

os::test::junit::declare_suite_start "cmd/idle/all"
setup_idling_resources
os::cmd::expect_success_and_text 'oc idle --all' "The service will unidle DeploymentConfig \"${project}/${dc_name}\" to 2 replicas once it receives traffic"
os::cmd::expect_success_and_text "oc get endpoints idling-echo -o go-template='${idled_at_template}'" '.'
#os::cmd::expect_success_and_text "oc get endpoints idling-echo -o go-template='${unidle_target_template}' | jq '.[] | select(.name == \"${dc_name}\") | (.replicas == 2 and .kind == \"DeploymentConfig\")'" 'true'
os::test::junit::declare_suite_end

os::test::junit::declare_suite_start "cmd/idle/check-previous-scale"
setup_idling_resources  # scales up to 2 replicas
os::cmd::expect_success_and_text 'oc idle idling-echo' "The service will unidle DeploymentConfig \"${project}/${dc_name}\" to 2 replicas once it receives traffic"
os::cmd::expect_success_and_text "oc get dc ${dc_name}  -o go-template='${prev_scale_template}'" '2'  # we see the result of the initial scale as the previous scale
os::test::junit::declare_suite_end

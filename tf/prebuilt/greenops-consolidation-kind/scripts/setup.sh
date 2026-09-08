#!/usr/bin/env bash
#
# Setup for the greenops-consolidation task. Runs from OUTSIDE the cluster during
# `tofu apply`, before the agent starts:
#   1. labels the four worker nodes with a machine family, two of each. The two
#      that sort first are 'n2d-standard-4' (the efficient gen4 family), the two
#      that sort last are 'n1-standard-4' (the power-hungry gen1 family). This is
#      the ONLY place in the cluster the two pools differ, and it is the join key
#      for the delivered carbon feed's per-family power figures,
#   2. deploys a lightly-loaded fleet across the cluster. With four empty workers
#      at bring-up the scheduler spreads the workloads roughly one-per-node, so
#      every worker carries a little load — the underutilized, energy-wasteful
#      "before" state the agent must consolidate,
#   3. waits for the fleet to become Available so the agent starts healthy.
#
# The kubectl work isn't expressible as plan-time-safe declarative TF (kind has no
# cluster at plan time); the carbon report is delivered declaratively by a
# local_file resource in main.tf, not here.
#
# Nothing here tells the agent which nodes to drain, how far to consolidate, or
# that draining is the mechanism at all. It must read the feed, join it to the
# node labels, inspect the workloads' scheduling constraints, and decide itself.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
MANIFESTS_DIR="${MANIFESTS_DIR:?MANIFESTS_DIR is required}"
MANIFESTS_DIR="$(cd "${MANIFESTS_DIR}" && pwd)"

# kind names multi-node workers '<cluster>-worker', '-worker2', '-worker3',
# '-worker4', which sort in that order — so this mapping is deterministic and the
# task's verification_spec can name the high-draw pair directly. If the stack ever
# grows a fifth worker, the spec's node names must move with it.
echo "==> Labelling the worker nodes with their machine family..."
mapfile -t WORKERS < <(
  kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort
)
if [[ "${#WORKERS[@]}" -ne 4 ]]; then
  echo "ERROR: expected 4 worker nodes, found ${#WORKERS[@]}: ${WORKERS[*]}" >&2
  exit 1
fi
kubectl label node "${WORKERS[0]}" "${WORKERS[1]}" \
  node.kubernetes.io/instance-type=n2d-standard-4 --overwrite
kubectl label node "${WORKERS[2]}" "${WORKERS[3]}" \
  node.kubernetes.io/instance-type=n1-standard-4 --overwrite

echo "==> Deploying the workload fleet across the worker nodes..."
kubectl apply -f "${MANIFESTS_DIR}/workloads/"

echo "==> Waiting for the fleet to become Available..."
# Start the agent from a healthy fleet so any unavailability during consolidation
# is the agent's doing, not a flaky fixture.
kubectl -n workloads wait --for=condition=Available deploy --all --timeout=300s

echo "==> Setup complete."
echo "    Node pools:    kubectl get nodes -L node.kubernetes.io/instance-type"
echo "    Pod placement: kubectl -n workloads get pods -o wide"

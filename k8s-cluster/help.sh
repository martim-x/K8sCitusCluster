kubectl create namespace citus
helm upgrade --install citus . -n citus

kubectl port-forward -n citus svc/coordinator-1 15431:5432
kubectl port-forward -n citus svc/coordinator-2 15432:5432
kubectl port-forward -n citus svc/coordinator-3 15433:5432

kubectl port-forward -n citus svc/master-1 15421:5432
kubectl port-forward -n citus svc/master-2 15422:5432
kubectl port-forward -n citus svc/master-3 15423:5432

kubectl port-forward -n citus svc/pg-locker 15440:5432

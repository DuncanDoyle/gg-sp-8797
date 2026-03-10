#!/bin/sh

pushd ..

# Deploy the Gateway (Gloo Edge API)
kubectl apply -f gateways/gateway-proxy.yaml

# Create namespaces
kubectl create namespace httpbin --dry-run=client -o yaml | kubectl apply -f -

# Deploy the HTTPBin application
printf "\nDeploy HTTPBin application ...\n"
kubectl apply -f apis/httpbin.yaml

# Deploy the shared RouteOption
printf "\nDeploy RouteOption ...\n"
kubectl apply -f policies/simple-rto.yaml

# Deploy the RouteTables
printf "\nDeploy RouteTables ...\n"
kubectl apply -f routetables/api-routes-rt.yaml
kubectl apply -f routetables/ping-routes-rt.yaml

# Deploy the VirtualService
printf "\nDeploy VirtualService ...\n"
kubectl apply -f virtualservices/api-example-com-vs.yaml

popd

#!/bin/bash
## Copyright (c) 2021 Oracle and/or its affiliates.
## Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl/


echo delete inventory-dotnet deployment...

kubectl delete deployment inventory-dotnet -n msdataworkshop

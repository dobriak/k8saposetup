# k8saposetup

### Automated Kubernetes configuration for Aporeto

*Overrides*
* APORETO_RELEASE="release-3.11.15"
* CLUSTER_NAME="mycluster1"

### Usage

You could do

```
wget https://raw.githubusercontent.com/dobriak/k8saposetup/master/k8saposetup.sh
chmod +x k8saposetup.sh
# Inspect, ie 'vim k8saposetup.sh'
# Pass overrides with 'export VAR=value'
./k8saposetup.sh
```


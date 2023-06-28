# this is my env variable file

variable1=value1
variable2=value2
variable3=value3
variable4=value4

# NAME      DATA        AGE
# env-cm    4           76s
# kubectl create cm env-cm --from-env-file=env.sh

# when you describe config map, will notice that extra lines and comment get venished
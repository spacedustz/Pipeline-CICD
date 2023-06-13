#!/bin/bash

# 가동중인 Spring Boot 컨테이너 중지 & 삭제
docker ps -a -q --filter "name=cosmic" | grep -q . && docker stop cosmic && docker rm cosmic | true

# 가동중인 Spring Boot 컨테이너 중지 & 삭제
if docker ps -a --filter "name=cosmic" | grep -q cosmic; then
    docker stop cosmic
    docker rm cosmic
fi

# 기존 Spring Boot Image 삭제
if docker images | awk '{print $1":"$2}' | grep -q "43.201.243.115:5000/cosmic:1.0"; then
    docker rmi -f 43.201.243.115:5000/cosmic:1.0
fi

# Docker Private Container Registry에 이미지 Pull
docker pull 43.201.243.115:5000/cosmic:1.0

# Docker run
docker run -d --privileged --name cosmic -p 8080:8080 43.201.243.115:5000/cosmic:1.0

# 사용하지 않는 불필요한 이미지 삭제
dangling_images=$(docker images -f "dangling=true" -q)
if [[ -n "$dangling_images" ]]; then
    docker rmi -f $dangling_images || true
fi
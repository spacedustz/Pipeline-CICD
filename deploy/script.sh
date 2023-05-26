#!/bin/bash

echo hello

# 가동중인 Spring Boot 컨테이너 중지 & 삭제
docker ps -a -q --filter "name=cosmic" | grep -q . && docker stop cosmic && docker rm cosmic | true

# 기존 Spring Boot Image 삭제
docker rmi 43.201.243.115:5000/cosmic:1.0

# Docker Private Container Registry에 이미지 Pull
docker pull 43.201.243.115:5000/cosmic:1.0

# Docker run
docker run -d --privileged --name cosmic -p 8080:8080 -v /root/logs:/logs 43.201.243.115:5000/cosmic:1.0

# 사용하지 않는 불필요한 이미지 삭제
docker rmi -f ${docker images -f "dangling=true" -q} || true
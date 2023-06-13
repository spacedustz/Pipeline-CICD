#!/bin/bash

# Gradlew 권한 부여
chmod 500 ./gradlew

# 빌드
./gradlew build --exclude-task test

# 가동중인 Spring Boot 컨테이너 중 이름이 cosmic 인 컨테이너 중지 & 삭제
if docker ps -a --filter "name=cosmic" | grep -q cosmic; then
    docker stop cosmic
    docker rm cosmic
fi

# 기존 Spring Boot Image 중 이미지가 기존과 똑같은게 있으면 이미지 삭제
if docker images | awk '{print $1":"$2}' | grep -q "localhost:5000/cosmic:1.0"; then
    docker rmi -f localhost:5000/cosmic:1.0
fi

# Docker Hub Login & 파라미터는 젠킨스에서 설정한 전역변수 사용
echo $PASSWORD | docker login -u $USERNAME --password-stdin

# 도커파일 빌드
docker build --no-cache -t localhost:5000/cosmic:1.0 -f ./spacepet-deploy/test/cosmic .

# Container Registry에 이미지 Push
docker push localhost:5000/cosmic:1.0

# Push한 이미지 삭제
docker rmi localhost:5000/cosmic:1.0

# Container Registry에서 이미지 Pull
docker pull localhost:5000/cosmic:1.0

# Docker Container 생성
docker run -d -v /root/docker_volumn/cosmic:/app --privileged --name cosmic -p 8080:8080 localhost:5000/cosmic:1.0

# 사용하지 않는 불필요한 이미지 삭제 = 겹치는 이미지가 존재하면 이미지를 삭제한다
dangling_images=$(docker images -f "dangling=true" -q)
if [[ -n "$dangling_images" ]]; then
    docker rmi -f $dangling_images || true
fi
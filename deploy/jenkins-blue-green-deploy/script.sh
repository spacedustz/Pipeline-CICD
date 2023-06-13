#!/bin/bash

# Blue & Green 타겟 지정 변수
target=2
deployment_target_ip=""
blue_ip=""
green_ip=""

# Gradlew 권한 부여
chmod 500 ./gradlew

# 빌드
#./gradlew clean build --exclude-task test

# 테스트용 빠른 빌드
./gradlew bootJar

# Blue Health Check
if curl -s "http://$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' blue):8080/ttt" > /dev/null; then
 deployment_target_ip=docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' green
 green_ip=$deployment_target_ip
 target=0
else
 deployment_target_ip=docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' blue
 blue_ip=$deployment_target_ip
 target=1
fi

# Target과 일치하는 가동중인 Spring Boot 컨테이너 중지 & 삭제
if [ "$target" -eq 0 ]; then
 if docker ps -a --filter "name=green" | grep -q green; then
  docker stop green
  docker rm green
  fuser -s -k 8080/tcp
 fi

 # 기존 Spring Boot Image 중 이미지가 기존과 똑같은게 있으면 이미지 삭제
 if docker images | awk '{print $1":"$2}' | grep -q "localhost:5000/green:1.0"; then
   docker rmi -f localhost:5000/green:1.0
  fi

elif [ "$target" -eq 1 ]; then
  if docker ps -a --filter "name=blue" | grep -q blue; then
  docker stop blue
  docker rm blue
  fuser -s -k 8080/tcp
 fi

 # 기존 Spring Boot Image 중 이미지가 기존과 똑같은게 있으면 이미지 삭제
 if docker images | awk '{print $1":"$2}' | grep -q "localhost:5000/blue:1.0"; then
   docker rmi -f localhost:5000/blue:1.0
  fi
else
 echo "Invalid target Value"
fi

# Docker Hub Login & 파라미터는 젠킨스에서 설정한 전역변수 사용
echo $PASSWORD | docker login -u $USERNAME --password-stdin

# 도커파일 빌드
if [ "${deployment_target_ip}" == "${blue_ip}" ]; then
 docker build --no-cache -t localhost:5000/blue:1.0 -f ./spacepet-deploy/test/blue .

 # Container Registry에 이미지 Push docker push localhost:5000/blue:1.0

 # Push한 이미지 삭제
 docker rmi localhost:5000/blue:1.0

 # Container Registry에서 이미지 Pull docker pull localhost:5000/blue:1.0

 # Docker Container 생성
 docker run -d -v /root/docker_volumn/blue:/app --network deploy --ip 172.20.0.2 --privileged --name blue -p 8080:8080 localhost:5000/blue:1.0

elif [ "${deployment_target_ip}" == "${green_ip}" ]; then
 docker build --no-cache -t localhost:5000/green:1.0 -f ./spacepet-deploy/test/green .

 # Container Registry에 이미지 Push docker push localhost:5000/green:1.0

 # Push한 이미지 삭제
 docker rmi localhost:5000/green:1.0

 # Container Registry에서 이미지 Pull docker pull localhost:5000/green:1.0

 # Docker Container 생성
 docker run -d -v /root/docker_volumn/green:/app --network deploy --ip 172.20.0.3 --privileged --name green -p 8080:8080 localhost:5000/green:1.0
else
 echo "Invalid target Value"
fi

# 사용하지 않는 불필요한 이미지 삭제 = 겹치는 이미지가 존재하면 이미지를 삭제한다
dangling_images=$(docker images -f "dangling=true" -q)
if [[ -n "$dangling_images" ]]; then
    docker rmi -f $dangling_images || true
fi

# Nginx Reverse Proxy 방향 (타겟 컨테이너) 변경
ssh root@${nginx_ip} "echo 'set \\\$service_url http://${deployment_target_ip}:8080;' > /etc/nginx/conf.d/service-url.inc && service nginx reload"
echo "Switch the reverse proxy direction of nginx to ${deployment_target_ip} 🔄"
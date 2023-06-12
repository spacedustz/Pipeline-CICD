# Pipeline-CICD
- Test Github Actions + AWS Code Deploy & S3 & EC2 [Done]
- Test Jenkins + AWS Lightsail [Done]
- Declarative Pipeline [Done]
- Blue & Green Zero-Downtime Deployment [Done]

---
## Jenkins Pipeline 구축

Jenkins의 Item중 선언형 Pipeline으로 구축을 완료해서 글을 작성합니다.

<br>

저번에 Free Style Project로 Jenkins CICD를 구현했었는데, 요구사항이 변경함에 따라 Declarative Pipeline Script를 이용한 Jenkins CICD를 구축해보았습니다.

스크립트를 먼저 작성해놓고 Pipeline을 구축해보도록 하겠습니다!!

<br>

`Jenkins Credential, JDK, Gradle, SSH, Token 등 Jenkins Web에서의 모든 설정이 완료되었다는 가정하에 글을 썼습니다.`

<br>

**내용 추가 (Jenkins Git 관련 이슈 해결)**

1. Jenkins Credentials의 SSH와 프로젝트 구성의 SSH가 일치하는지 체크
2. 만약 SSH로 Credentials를 구성했다면 프로젝트 구성의 프로젝트 URL도 ssh URL로 작성해야 합니다.
3. Jenkins Server의 /var/lib/jenkins 디렉터리나 그 하위의 파일들의 권한, 소유자 확인 필수 ( 소유자: jenkins:jenkins 로 해야함)
4. EC2 jenkins user의 .ssh 하위 파일들의 권한, 소유자 확인
5. known_host에 EDSDA 키 추가 됐는지 확인

<br>

```bash
# Jenkins 디렉터리 하위 모든 파일들의 소유권 변경
chown -R jenkins:jenkins/var/lib/jenkin

# Jenkins User의 ssh 파일들 소유자, 권한 변경
chown -R jenkins:jenkins /var/lib/jenkins/.ssh
chmod 600 /var/lib/jenkins/.ssh/id_rsa
chmod 644 /var/lib/jenkins/.ssh/id_rsa.pub
```

---

## Jenkins Server

EC2 m5a.large 인스턴스를 사용했으며 AMI는 Ubuntu 20.04 LTS입니다.

root 계정으로 진행했으며 보안그룹 포트는 이미 열어놓은 상태에서 서버 세팅 스크립트를 작성해 서버를 세팅하였습니다.

<br>

### 서버 세팅 스크립트 작성

기본적인 패키지들과 방화벽 설정, Docker, Jenkins를 설치하고 스텝을 진행할때마다 로그 파일에 기록합니다.

```bash
#!/bin/bash


# APT 업데이트
apt-get -y update
ate-get -y upgrade
echo ----- APT Update 종료 ---- | tee settinglogs


# 기본 패키지 설치
apt install -y firewalld mysql-client net-tools curl wget gnupg lsb-release ca-certificates apt-transport-https software-properties-common gnupg-agent openjdk-11-jdk
echo ----- 기본 패키지 설치 완료 ----- >> settinglogs


# OpenJDK 전역변수 설정
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
echo ----- $JAVA_HOME ----- >> settinglogs


# Firewalld 시작
systemctl start firewalld && systemctl enable firewalld
echo ----- Firewalld 시작 ----- >> settinglogs


# 포트 오픈
firewall-cmd --permanent --add-port=22/tcp
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-port=5000/tcp
firewall-cmd --permanent --add-port=8080/tcp
firewall-cmd --permanent --add-port=18080/tcp
firewall-cmd --permanent --add-port=13306/tcp

# Jenkins < - > Github Webhook을 위한 IP 허용
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address=192.30.252.0/22 port port="22" protocol="tcp" accept' && firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address=185.199.108.0/22 port port="22" protocol="tcp" accept' && firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address=140.82.112.0/20 port port="22" protocol="tcp" accept' && firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address=143.55.64.0/20 port port="22" protocol="tcp" accept' && firewall-cmd --permanent --add-rich-rule='rule family="ipv6" source address=2a0a:a440::/29 port port="22" protocol="tcp" accept' && firewall-cmd --permanent --add-rich-rule='rule family="ipv6" source address=2606:50c0::/32 port port="22" protocol="tcp" accept'


# Firewall Settings 저장
firewall-cmd --reload
echo ----- Firewalld 설정 완료 ----- >> settinglogs


# 도커 설치

## 도커 GPG Key 추가
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

## 도커 저장소 설정
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

## 도커 엔진 설치
apt install -y docker-ce docker-ce-cli containerd.io
echo ----- 도커 설치 완료 ----- >> settinglogs

## 도커 시작
systemctl start docker && systemctl enable docker
echo ----- 도커 시작 ----- >> settinglogs


# 젠킨스 설치
wget -q -O - https://pkg.jenkins.io/debian-stable/jenkins.io.key | sudo apt-key add -

curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | sudo tee \
  /usr/share/keyrings/jenkins-keyring.asc > /dev/null

echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
  https://pkg.jenkins.io/debian-stable binary/ | sudo tee \
  /etc/apt/sources.list.d/jenkins.list > /dev/null

apt -y update

apt install -y jenkins
echo ----- Jenkins 설치 완료 ----- >> settinglogs

# 도커, sudo 권한 부여
usermod -aG docker jenkins
usermod -aG sudo jenkins
chmod 666 /var/run/docker.sock


# 젠킨스 포트 변경
sed -i 's/8080/18080/g' /usr/lib/systemd/system/jenkins.service


# 젠킨스 시작
systemctl start jenkins && systemctl enable jenkins
echo ----- Jenkins 시작 완료 ----- >> settinglogs
```

<br>

### 상태 확인용 스크립트

```bash
#!/bin/bash

echo -e "\033[31m"=== Firewalld Port Status ==="\033[0m"
firewall-cmd --list-all


echo -e "\033[31m"=== Docker Status ==="\033[0m"
systemctl status docker | grep active


echo -e "\033[31m"=== Jenkins Status ==="\033[0m"
systemctl status jenkins | grep active
```

---

## script.sh

Jenkinsfile의 조건들을 통과하고, Build Stage에서 사용될 스크립트를 작성하였습니다.

작성한 스크립트를 요약하면 이렇습니다.

1. gradlew 파일에 실행권한 추가
2. gradlew 빌드
3. 전에 빌드한 컨테이너 중지 &  삭제
4. 빌드했던 이미지 삭제
5. 도커 Hub 로그인
6. 새로운 빌드의 Dockerfile 빌드
7. 구축해놓은 Docker Container Registry에 빌드한 이미지 Push
8. Push한 이미지 삭제
9. Push했던 이미지 Pull
10. 가져온 이미지를 이용하여 컨테이너 실행 + 볼륨 마운트 + 포트포워딩
11. 중복된 이미지 삭제

```bash
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
```

<br>

`dangling Image`란?

동일한 태그를 가진 Docker Image가 빌드될 경우, 기존에 있는 이미지는 삭제되지도 않고,

tag가 none으로 변경된 상태로 남게 됩니다.

즉, 재 빌드시 이전 이미지를 삭제하고 새로운 이미지로 대체하겠다는 뜻입니다.

---

## Dockerfile

도커파일은 항상 도커파일이 있는 위치가 기준 경로입니다.

spacepet-deploy/test/cosmic 이니까

COPY 경로에 ../../ 를 해줘야합니다.

최대 힙사이즈를 6GB로 제한하면서 빌드합니다.

<br>

Workdir은 /app 인데 Jar파일을 컨테이너 최상단에 두는 이유는 

script.sh 스크립트에서 컨테이너 실행 시, 볼륨 마운트를 /app에 하는데,

그때 /app 하위에 있던 jar가 사라지므로 Jar파일을 최상단 디렉터리로 복사했습니다.

```dockerfile
FROM openjdk:11  
RUN mkdir -p /app    
WORKDIR /app    
VOLUME /app    
EXPOSE 8080  ARG JAR=dangnyang-1.7.08-SNAPSHOT.jar    
COPY ../../build/libs/${JAR} /koboot.jar  
RUN chmod +x /koboot.jar  
ENTRYPOINT ["java","-jar","-Dspring.profiles.active=test","-Xmx6144M","/koboot.jar"]
```

---

## Jenkinsfile

Jenkinsfile에서 Git repo에 체크아웃을 하고

원하는 브랜치, 태그 등 필터링 옵션들을 넣어 빌드 실행 전 조건을 걸어둡니다.

<br>

**Stage: Clean Workspace 항목**
빌드가 실행되기 전 Workspace를 비웁니다.

<br>

**Stage: Checkout 항목**
등록한 Jenkins Credential을 이용해 Git Repo에 Checkout을 합니다.

<br>

**Stage: Build 항목**
조건이 일치하면 그때 위에 작성한 script.sh를 실행시키며 script.sh 스크립트 내부에서 Dockerfile을 빌드합니다.


```groovy
pipeline {  
  agent any  
  
  stages {  
  
    stage('Clean Workspace') {  
      steps {  
        deleteDir()  
      }  
    }  
  
    stage('Checkout') {  
      steps {  
        script {  
          checkout([$class: 'GitSCM',  
  
          branches: [[name: '<branch-name>']],  
          userRemoteConfigs: [[  
          url: 'git@github.com:<user-name>/<repo-name>.git',  
          branch: 'SPACEPET-TEST',  
          credentialsId: '<jenkins-credentials-id>']]])  
        }  
      }  
    }  
  
    stage('Build') {  
      steps {  
        script {  
          def gitTags = sh(returnStdout: true, script: 'git tag --contains HEAD')  
          if (gitTags.contains('cicd')) {  
            sh 'chmod 500 spacepet-deploy/test/script.sh'  
            sh './spacepet-deploy/test/script.sh'  
          } else {  
            echo 'No tag containing "cicd" found.'  
          }  
        }  
      }  
    }  
  }  
}
```

---

## Pipeline (Item) 생성

<br>

### General

Github Project 선택하고 Project URL을 써줍니다. (.git 포함)

`git@github.com:<user-name>/<repo-name>.git`

<br>

### Build Triggers

Github hook trigger for GITScm polling을 선택해줍니다.

<br>

### Pipeline

<br>

**Definition 항목**

`Pipeline script from SCM` 으로 선택합니다.

<br>

**SCM 항목**

`Git` 으로 선택합니다.

<br>

**Repository URL 항목**

`git@github.com:<user-name>/<repo-name>.git` 의 형식으로 작성해줍니다.

<br>

**Credentials 항목**

Jenkins Credential에 등록한 Jenkins Server의 Jenkins User SSH를 등록했던 Credentials를 선택합니다.

이 후 밑에 고급 버튼을 눌러줍니다.

<br>

**RefSpec 항목**

Name은 아무렇게나 적고 Refspec에 원하는 브랜치를 입력합니다.

`+refs/heads/SPACEPET-TEST:refs/remotes/origin/SPACEPET-TEST`

<br>

**Branch Specifier 항목**

`*/SPACEPET-TEST`  <- 저는 SPACEPET-TEST 라는 브랜치를 빌드 대상으로 정했습니다.

<br>

**Script Path 항목**

빌드 대상에 Jenkinsfile이 위치한 경로를 적어줍니다. (Pipeline Script 위치)

`spacepet-deploy/test/Jenkinsfile`

<br>

### Pipeline Script 정상 동작

1. Spring Boot에서 설정한 브랜치에서 태그를 이용한 Push
2. Github Webhook Trigger 발동 -> Jenkins로 Webhook 전송
3. Jenkins가 Webhook을 받고 Jenkinsfile을 실행
4. Jenkinsfile에 걸린 조건 필터링 (브랜치, 태그)
5. 브랜치와 태그가 맞으면 Jenkinsfile의 Build Stage에 script.sh 실행 스크립트 발동
6. script.sh 스크립트 실행

<br>

100번의 삽질끝에 겨우 성공.. Jenkins 너무 불친절한것 같습니다 ㅠ

![img](https://raw.githubusercontent.com/spacedustz/Obsidian-Image-Server/main/img/jenkinspipeline2.png)

<br>

<img src="https://raw.githubusercontent.com/spacedustz/Obsidian-Image-Server/main/img/jenkinspipeline.png" width="60%" height="60%" />

<br>

Jenkins Server인 EC2에 `docker ps`를 입력해보면 Springboot 컨테이너가 정상적으로 띄워지고 볼륨 마운트도 잘 된걸 볼 수 있습니다.


---

## 다른 방법

Dockerfile이나 script.sh를 작성 안하고 Pipeline에 전부 작성하는 방법입니다.

이 방법의 장점은 Stage 별로 단계를 분류함으로써 Jenkins Web에서 진행 상황을 GUI로 편리하게 눈으로 볼 수 있습니다.

근데 위에 방법이 더 익숙해서 이건 그냥 연습만 해놓고 안쓰겠습니다.

```groovy
pipeline {  
  agent any  
  
  stages {  
  
    stage('Stop & Delete Container') {  
      when {  
        allOf {  
          branch 'SPACEPET-TEST'  
          tag 'cicd*'  
        }  
      }  
      steps {  
        sh '''  
          if docker ps -a --filter "name=cosmic" | grep -q cosmic; then              docker stop cosmic              docker rm cosmic          fi        '''      }  
    }  
  
    stage('Remove Image') {  
      when {  
        allOf {  
          branch 'SPACEPET-TEST'  
          tag 'cicd*'  
        }  
      }  
      steps {  
        sh '''  
          if docker images | awk '{print $1":"$2}' | grep -q "localhost:5000/cosmic:1.0"; then              docker rmi -f localhost:5000/cosmic:1.0          fi        '''      }  
    }  
  
    stage('Login Docker Hub') {  
      when {  
        allOf {  
          branch 'SPACEPET-TEST'  
          tag 'cicd*'  
        }  
      }  
      steps {  
        sh 'echo $PASSWORD | docker login -u $USERNAME --password-stdin'  
      }  
    }  
      
    stage('Git Clone') {  
      when {  
        allOf {  
          branch 'SPACEPET-TEST'  
          tag 'cicd*'  
        }  
      }  
      steps {  
        git branch: 'SPACEPET-TEST', url:'https://github.com/CosmicDangNyang/CosmicDangNyang-Server'  
      }  
    }  
  
    stage('Build') {  
      when {  
        allOf {  
          branch 'SPACEPET-TEST'  
          tag 'cicd*'  
        }  
      }  
      steps {  
        sh 'chmod 500 ./gradlew'  
        sh './gradlew build --exclude-task test'  
      }  
    }  
  
    stage ('Build Dockerfile') {  
      when {  
        allOf {  
          branch 'SPACEPET-TEST'  
          tag 'cicd*'  
        }  
      }  
      steps {  
        sh 'docker build --no-cache -t localhost:5000/cosmic:1.0 -f ./spacepet-deploy/test/cosmic .'  
      }  
    }  
  
    stage ('Container Registry - Push & Delete & Pull') {  
      when {  
        allOf {  
          branch 'SPACEPET-TEST'  
          tag 'cicd*'  
        }  
      }  
      steps {  
        script {  
          sh 'docker push localhost:5000/cosmic:1.0'  
          sh 'docker rmi localhost:5000/cosmic:1.0'  
          sh 'docker pull localhost:5000/cosmic:1.0'  
        }  
      }  
    }  
  
    stage ('Run Container') {  
      when {  
        allOf {  
          branch 'SPACEPET-TEST'  
          tag 'cicd*'  
        }  
      }  
      steps {  
        sh 'docker run -d -v /root/docker_volumn/cosmic:/ --privileged --name cosmic -p 8080:8080 localhost:5000/cosmic:1.0'  
      }  
    }  
  
    stage ('Delete Conflict Image') {  
      when {  
        allOf {  
          branch 'SPACEPET-TEST'  
          tag 'cicd*'  
        }  
      }  
      steps {  
        sh '''  
          dangling_images=$(docker images -f "dangling=true" -q)          if [[ -n "$dangling_images" ]]; then              docker rmi -f $dangling_images || true          fi        '''      }  
    }  
  
  }  
}
```

---

## 무중단 배포 -  Blue Green Deployment

지난번에 구축한 Jenkins + Github Webhook Trigger + AWS EC2, RDS ELB를 연동해서 간단한 CICD 배포 성공을 하고,

사내 요구사항 변경으로 무중단 배포(zero-downtime)를 구축한 기록을 작성합니다.

<br>

![](https://raw.githubusercontent.com/spacedustz/Obsidian-Image-Server/main/img/bluegreen.png)

<br>

### 설계할 배포 구조

1. 새로운 버전이 Git에 병합되면, **Github Webhook**을 통해 Jenkins에 신호가 들어오고, 젠킨스는 **최신 버전의 Jar 파일을 빌드**합니다.
2. 젠킨스는 **Blue에 Health check**를 합니다. Blue가 살아있다면 신버전을 Green에 배포하면 되고, 살아있지 않다면 Blue에 배포하면 됩니다.
3. 그림상 Blue가 살아있는 것으로 판단됩니다. 따라서 젠킨스는 Green에 배포를 하겠습니다.
4. 젠킨스는 **Green에 맨 처음 빌드해둔 Jar 파일을 전송**하고, 원격지에서 **실행**합니다.
5. Green의 애플리케이션이 구동되었는지 **10초 주기로 Health Check**를 합니다. Green 애플리케이션이 기동됨을 확인하면 (6)으로 넘어갑니다.
6. **Nginx의 리버스 프록시 방향을 Blue에서 Green으로 변경**합니다. 이제 클라이언트의 모든 트래픽이 신버전 애플리케이션으로 향합니다.
7. Blue 인스턴스의 애플리케이션 프로세스를 죽입니다.

---

### Nginx Reverse Proxy 설정

가용성을 위해 Nginx의 포트 리다이렉트를 8080 실패 시 8081로 포트 2개를 설정하였습니다.

Nginx Logging을 위해 로그 설정도 해주었습니다.

<br>

**nginx.conf**

```php
upstream docker-spring {  
      server localhost:8080 weight=10 max_fails=3 fail_timeout=10s;  
      server localhost:8081 weight=5 max_fails=3 fail_timeout=10s;  
}

server {
    listen 80;
    server_name localhost;

    include /etc/nginx/conf.d/service-url.inc;

    location / {
        proxy_pass $service_url;
        proxy_redirect     off;
        proxy_http_version 1.1;
        proxy_set_header   Host $http_host;
        proxy_set_header   Connection "";
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Host $server_name;
    }

		client_max_body_size 100M;

		access_log /var/log/nginx/access.log;
		error_log /var/log/nginx/error.log;
}
```

<br>

위 설정을 보면 `include` 라는 지시어를 사용하는 것을 볼 수 있습니다. 

이는 외부에서 설정 파일을 불러올 수 있는 Nginx 의 기능입니다.

`location`의 `proxy_pass` 를 보면, `$service_url` 로 리버스 프록시 요청을 보내는 것을 알 수 있는데,

`service-url.inc` 에서 이 `$service_url` 변수 값을 채워줍니다.

**service-url.inc**
```php
set $service_url http://XXX.XXX.XXX.XXX:8080;
```

<br>

**_location_**
- proxy_pass : 사용중인 프록시 URL을 입력 해줍니다.
- proxy_redirect : 프록시 리다이렉트는 사용을 하지 않겠습니다.
- proxy_http_version : HTTP 1.1을 사용합니다.

---

### Jenkins 설정

**_환경변수 설정_**
- nginx_ip, blue_ip, green_ip 3개의 변수를 만들어 각각 인스턴스 IP 주소를 값으로 넣어줍니다.

<br>

**_도커 네트워크 생성_**

제 경우에는 각각의 인스턴스가 아닌 컨테이너 끼리 Blue, Green 배포를 할것이고 Jenkins의 환경변수에 IP를 작성해야 합니다.

그래서 도커 네트워크를 만들어 줌으로써, Container의 IP를 고정시켜서 변경되지 않게 합니다.

기본 bridge0에 할당되어 있으면 컨테이너는 재시작 할때마다 IP가 바뀌게 됩니다.

즉, 새로운 Docker Bridge를 만들고 컨테이너들을 기본 bridge0이 아닌 Custom Bridge에 할당시킵니다.

<br>

```bash
docker network create --gateway 172.20.0.1 --subnet 172.20.0.0/16 deploy
```

이 후, docker run을 할 때 --network deploy 옵션과 --ip 172.20.0.X 로 아이피를 할당하면 됩니다.

<br>

**_스크립트 수정_**

```bash
#!/bin/bash  

# Blue & Green 타겟 지정 변수
target=2
deployment_target_ip=""

# Gradlew 권한 부여  
chmod 500 ./gradlew  
  
# 빌드  
#./gradlew clean build --exclude-task test

# 테스트용 빠른 빌드
./gradlew bootJar

# Blue Health Check
if curl -s "http://$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' blue):8080" > /dev/null 
then
	deployment_target_ip=$green_ip
	target=0
else
	deployment_target_ip=$blue_ip
	target=1
fi
  
# Target과 일치하는 가동중인 Spring Boot 컨테이너 중지 & 삭제  
if [ "$target" -eq 1 ]; then
	if docker ps -a --filter "name=green" | grep -q green; then  
		docker stop green
		docker rm green 
		fuser -s -k 8080/tcp
	fi

	# 기존 Spring Boot Image 중 이미지가 기존과 똑같은게 있으면 이미지 삭제  
	if docker images | awk '{print $1":"$2}' | grep -q "localhost:5000/green:1.0"; then  
	  docker rmi -f localhost:5000/green:1.0  
  fi
  
elif [ "$target" -eq 2 ]; then
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
	
	# Container Registry에 이미지 Push
	docker push localhost:5000/blue:1.0  
  
	# Push한 이미지 삭제  
	docker rmi localhost:5000/blue:1.0  
  
	# Container Registry에서 이미지 Pull
	docker pull localhost:5000/blue:1.0

	# Docker Container 생성  
	docker run -d -v /root/docker_volumn/blue:/app --network deploy --ip 172.20.0.2 --privileged --name blue -p 8080:8080 localhost:5000/blue:1.0  
	
elif [ "${deployment_target_ip}" == "${green_ip}" ]; then
	docker build --no-cache -t localhost:5000/green:1.0 -f ./spacepet-deploy/test/green .
	
	# Container Registry에 이미지 Push
	docker push localhost:5000/green:1.0  
  
	# Push한 이미지 삭제  
	docker rmi localhost:5000/green:1.0  
  
	# Container Registry에서 이미지 Pull
	docker pull localhost:5000/green:1.0

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
```

---

### Jenkinsfile 

```groovy
pipeline {  
  agent any  
  
  stages {  
  
    stage('Clean Workspace') {  
      steps {  
        deleteDir()  
      }  
    }  
  
    stage('Checkout') {  
      steps {  
        script {  
          checkout([$class: 'GitSCM',  
  
          branches: [[name: '<branch-name>']],  
          userRemoteConfigs: [[  
          url: 'git@github.com:<user-name>/<repo-name>.git',  
          branch: 'SPACEPET-TEST',  
          credentialsId: '<jenkins-credentials-id>']]])  
        }  
      }  
    }  
  
    stage('Build') {  
      steps {  
        script {  
          def gitTags = sh(returnStdout: true, script: 'git tag --contains HEAD')  
          if (gitTags.contains('cicd')) {  
            sh 'chmod 500 spacepet-deploy/test/script.sh'  
            sh './spacepet-deploy/test/script.sh'  
          } else {  
            echo 'No tag containing "cicd" found.'  
          }  
        }  
      }  
    }  
  }  
}
```

---

### Dockerfile

```dockerfile
FROM openjdk:11  
RUN mkdir -p /app    
WORKDIR /app    
VOLUME /app    
EXPOSE 8080  
ARG JAR=dangnyang-1.7.08-SNAPSHOT.jar    
COPY ../../build/libs/${JAR} /koboot.jar  
RUN chmod +x /koboot.jar  
ENTRYPOINT ["java","-jar","-Dspring.profiles.active=test","-Xmx6144M","/koboot.jar"]
```

// StreamingApp CI/CD: build -> push to Amazon ECR -> deploy to EKS with Helm
pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '15'))
        timeout(time: 45, unit: 'MINUTES')
    }

    environment {
        AWS_REGION     = 'ap-south-1'
        AWS_ACCOUNT_ID = '099739121791'
        ECR_REGISTRY   = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
        IMAGE_PREFIX   = "${ECR_REGISTRY}/streamingapp"
        CLUSTER_NAME   = 'streamingapp-eks'
        NAMESPACE      = 'streamingapp'
        SNS_TOPIC_ARN  = "arn:aws:sns:${AWS_REGION}:${AWS_ACCOUNT_ID}:streamingapp-deployments"
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.IMAGE_TAG = sh(script: 'git rev-parse --short=8 HEAD', returnStdout: true).trim()
                }
                echo "Building commit ${env.IMAGE_TAG}"
            }
        }

        stage('Check AWS account') {
            steps {
                // never deploy to the wrong account
                sh '''
                  ACTUAL=$(aws sts get-caller-identity --query Account --output text)
                  echo "AWS account: $ACTUAL"
                  test "$ACTUAL" = "$AWS_ACCOUNT_ID"
                '''
            }
        }

        stage('Login to ECR') {
            steps {
                sh 'aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY'
            }
        }

        stage('Build and push images') {
            steps {
                script {
                    def images = [
                        'frontend'         : 'frontend',
                        'auth-service'     : 'backend/authService',
                        'streaming-service': 'backend/streamingService',
                        'admin-service'    : 'backend/adminService',
                        'chat-service'     : 'backend/chatService',
                    ]
                    for (name in images.keySet()) {
                        def dir = images[name]
                        stage(name) {
                            sh """
                              docker build -t ${IMAGE_PREFIX}/${name}:${IMAGE_TAG} -t ${IMAGE_PREFIX}/${name}:latest ${dir}
                              docker push ${IMAGE_PREFIX}/${name}:${IMAGE_TAG}
                              docker push ${IMAGE_PREFIX}/${name}:latest
                            """
                        }
                    }
                }
            }
        }

        stage('Deploy to EKS (Helm)') {
            steps {
                sh '''
                  export KUBECONFIG=$WORKSPACE/.kubeconfig
                  aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION --kubeconfig $KUBECONFIG
                  helm lint helm/streamingapp
                  helm upgrade --install streamingapp helm/streamingapp \
                    --namespace $NAMESPACE \
                    --set image.tag=$IMAGE_TAG \
                    --wait --timeout 10m
                  kubectl -n $NAMESPACE get deploy,statefulset,hpa,svc
                '''
            }
        }
    }

    post {
        success {
            sh 'aws sns publish --region $AWS_REGION --topic-arn $SNS_TOPIC_ARN --subject "StreamingApp deploy SUCCESS #$BUILD_NUMBER" --message "Build #$BUILD_NUMBER deployed commit $IMAGE_TAG to EKS cluster $CLUSTER_NAME. $BUILD_URL" || true'
        }
        failure {
            sh 'aws sns publish --region $AWS_REGION --topic-arn $SNS_TOPIC_ARN --subject "StreamingApp deploy FAILED #$BUILD_NUMBER" --message "Build #$BUILD_NUMBER failed. Logs: $BUILD_URL" || true'
        }
        always {
            sh 'docker image prune -f || true'
        }
    }
}

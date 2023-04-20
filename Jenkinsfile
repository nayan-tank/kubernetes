pipeline{
    agent {label 'dev-agent'}
    stages{
        stage('Code Fetch'){
            steps{
                echo 'Code fetching...'
                git credentialsId: 'git_PAT', url: 'https://github.com/nayan-tank/django-todo-cicd.git', branch: 'master'
            }
        }
        stage('Build and Test'){
            steps{
                sh 'docker build -t nayan-tank/django-todo .'
            }
        }
        stage('Login and Push Image'){
            steps{
                withCredentials([usernamePassword(credentialsId: 'dockerHub', passwordVariable: 'dockerHubPass', usernameVariable: 'dockerHubUser')]){
                    sh 'docker login -u ${env.dockerHubUser} -p ${env.dockerHubPass}'
                    sh 'docker push nayan-tank/django-todo'
                }
            }
        }
        stage('Deploy'){
            steps{
                // use above image in docker compose file (image: nayan-tank/django-todo)
                sh 'docker-compose down && docker-compose up -d --no-deps'
            }
        }
    }
}




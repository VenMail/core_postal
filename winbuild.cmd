docker build -t ghcr.io/venmail/postal:latest .
docker tag ghcr.io/venmail/postal:latest ghcr.io/venmail/postal:2.7.18
docker push ghcr.io/venmail/postal:latest
docker push ghcr.io/venmail/postal:2.7.18
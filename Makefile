start:
	docker run -p 8080:80 nominatim

build:
	docker build -t nominatim .

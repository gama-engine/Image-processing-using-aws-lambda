#!/bin/bash

echo "Creating layer folder..."

mkdir -p layers/pillow_layer/python

echo "Installing Pillow..."

pip install pillow -t layers/pillow_layer/python

echo "Zipping layer..."

cd layers/pillow_layer
zip -r pillow_layer.zip python

echo "Lambda layer built successfully."

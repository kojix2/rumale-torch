# frozen_string_literal: true

require 'rumale/base/base_estimator'
require 'rumale/base/classifier'
require 'rumale/preprocessing/label_encoder'
require 'rumale/model_selection/function'

module Rumale
  module Torch
    # NeuralNetClassifier is a class that provides learning and inference by the neural network defined in torch.rb
    # with an interface similar to classifier of Rumale.
    #
    # @example
    #   require 'rumale/torch'
    #
    #   class MyNet < Torch::NN::Module
    #     def initialize
    #       super
    #       @dropout = Torch::NN::Dropout.new(p: 0.5)
    #       @fc1 = Torch::NN::Linear.new(2, 8)
    #       @fc2 = Torch::NN::Linear.new(8, 2)
    #     end
    #
    #     def forward(x)
    #       x = @fc1.call(x)
    #       x = Torch::NN::F.relu(x)
    #       x = @dropout.call(x)
    #       x = @fc2.call(x)
    #       Torch::NN::F.softmax(x)
    #     end
    #   end
    #
    #   device = Torch.device('gpu')
    #   net = MyNet.new.to(device)
    #
    #   classifier = Rumale::Torch::NeuralNetClassifier.new(model: net, device: device, batch_size: 50, max_epoch: 10)
    #   classifier.fit(x, y)
    #
    #   classifier.predict(x)
    #
    class NeuralNetClassifier
      include Base::BaseEstimator
      include Base::Classifier

      # Return the class labels.
      # @return [Numo::Int32] (size: n_classes)
      attr_reader :classes

      # Create a new classifier with neural nets defined by torch.rb.
      #
      # @param model [Torch::NN::Module] The neural nets defined with torch.rb.
      # @param device [Torch::Device/Nil] The compute device to be used.
      #   If nil is given, it to be set to Torch.device('cpu').
      # @param optimizer [Torch::Optim/Nil] The optimizer to be used to optimize the model.
      #   If nil is given, it to be set to Torch::Optim::Adam.
      # @param loss [Torch:NN] The loss function to be used to optimize the model.
      #   If nil is given, it to be set to Torch::NN::CrossEntropyLoss.
      # @param batch_size [Integer] The number of samples per batch to load.
      # @param max_epoch [Integer] The number of epochs to train the model.
      # @param shuffle [Boolean] The flag indicating whether to shuffle the data at every epoch.
      # @param validation_split [Float] The fraction of the training data to be used as validation data.
      # @param verbose [Boolean] The flag indicating whether to output loss during epoch.
      # @param random_seed [Integer/Nil] The seed value using to initialize the random generator for data splitting.
      def initialize(model:, device: nil, optimizer: nil, loss: nil,
                     batch_size: 128, max_epoch: 10, shuffle: true, validation_split: 0.1,
                     verbose: true, random_seed: nil)
        @params = method(:initialize).parameters.each_with_object({}) { |(_, kwd), obj| obj[kwd] = binding.local_variable_get(kwd) }
        @params[:device] ||= ::Torch.device('cpu')
        @params[:optimizer] ||= ::Torch::Optim::Adam.new(model.parameters)
        @params[:loss] ||= ::Torch::NN::CrossEntropyLoss.new
        @params[:random_seed] ||= srand
        @params.each_key do |name|
          self.class.send(:define_method, name) { @params[name] }
          self.class.send(:private, name)
        end
      end

      # Fit the model with given training data.
      #
      # @param x [Numo::DFloat] (shape: [n_samples, n_features]) The training data to be used for fitting the model.
      # @param y [Numo::Int32] (shape: [n_samples]) The labels to be used for fitting the model.
      # @return [NeuralNetClassifier] The learned classifier itself.
      def fit(x, y)
        encoder = Rumale::Preprocessing::LabelEncoder.new
        encoder.fit(y)
        @classes = Numo::NArray[*encoder.classes]

        x_train, x_test, y_train, y_test = Rumale::ModelSelection.train_test_split(
          x, y, test_size: validation_split, stratify: true, random_seed: random_seed
        )

        y_train = encoder.transform(y_train)
        y_test = encoder.transform(y_test)

        train_loader = torch_data_loader(x_train, y_train)
        test_loader = torch_data_loader(x_test, y_test)

        1.upto(max_epoch) do |epoch|
          train(train_loader)
          next unless verbose

          puts("Epoch: #{epoch}/#{max_epoch}")
          puts('loss: %.4f - accuracy: %.4f - val_loss: %.4f - val_accuracy: %.4f' % [
            evaluate(train_loader), evaluate(test_loader)
          ].flatten)
        end

        self
      end

      # Predict class labels for samples.
      #
      # @param x [Numo::DFloat] (shape: [n_samples, n_features]) The samples to predict the labels.
      # @return [Numo::Int32] (shape: [n_samples]) Predicted class label per sample.
      def predict(x)
        output = ::Torch.no_grad { model.call(::Torch.from_numo(x).to(:float32)) }
        _, indices = ::Torch.max(output, 1)
        @classes[indices.numo].dup
      end

      # Calculate confidence scores for samples.
      #
      # @param x [Numo::DFloat] (shape: [n_samples, n_features]) The samples to compute the scores.
      # @return [Numo::DFloat] (shape: [n_samples, n_classes]) The confidence score per sample.
      def decision_function(x)
        Numo::DFloat.cast(::Torch.no_grad { model.call(::Torch.from_numo(x).to(:float32)) }.numo)
      end

      private

      def torch_data_loader(x, y)
        x_tensor = ::Torch.from_numo(x).to(:float32)
        y_tensor = ::Torch.from_numo(y).to(:int64)
        dataset = ::Torch::Utils::Data::TensorDataset.new(x_tensor, y_tensor)
        ::Torch::Utils::Data::DataLoader.new(dataset, batch_size: batch_size, shuffle: shuffle)
      end

      def train(data_loader)
        model.train
        data_loader.each_with_index do |(data, target), _batch_idx|
          data = data.to(device)
          target = target.to(device)
          optimizer.zero_grad
          output = model.call(data)
          ls = loss.call(output, target)
          ls.backward
          optimizer.step
        end
      end

      def evaluate(data_loader)
        model.eval
        mean_loss = 0
        correct = 0
        ::Torch.no_grad do
          data_loader.each do |data, target|
            data = data.to(device)
            target = target.to(device)
            output = model.call(data)
            mean_loss += loss.call(output, target).item
            pred = output.argmax(1, keepdim: true).view(-1)
            correct += pred.eq(target.view_as(pred)).sum.item
          end
        end

        mean_loss /= data_loader.dataset.size
        accuracy = correct.fdiv(data_loader.dataset.size)
        [mean_loss, accuracy]
      end
    end
  end
end

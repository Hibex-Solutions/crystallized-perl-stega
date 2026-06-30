#!/usr/bin/env perl
# eng/worker.pl — inicia o NotificationWorker (consumidor RabbitMQ)
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Stega::Worker::NotificationWorker;

Stega::Worker::NotificationWorker::run();

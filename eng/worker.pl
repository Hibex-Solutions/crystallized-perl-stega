#!/usr/bin/env perl
# eng/worker.pl — inicia o NotificationWorker (consumidor RabbitMQ)
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
$| = 1;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Stega::Worker::NotificationWorker;

Stega::Worker::NotificationWorker::run();

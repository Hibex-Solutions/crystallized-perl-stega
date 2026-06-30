package Stega::Job::GenerateActivityReport;
use strict;
use warnings;

sub run {
    my ($job, $args) = @_;

    my $app        = $job->app;
    my $db         = $app->pg->db;
    my $product_id = $args->{product_id};

    my $products_query = $product_id
        ? $db->query('SELECT id, name FROM products WHERE id = $1', $product_id)
        : $db->query('SELECT id, name FROM products WHERE is_active = true');

    my @reports;
    for my $product (@{ $products_query->hashes }) {
        my $stats = $db->query(q{
            SELECT
                COUNT(*) FILTER (WHERE status = 'open')                    AS open_count,
                COUNT(*) FILTER (WHERE status = 'in_progress')             AS in_progress_count,
                COUNT(*) FILTER (WHERE status = 'resolved')                AS resolved_count,
                COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '7 days') AS created_last_7d,
                COUNT(*) FILTER (WHERE resolved_at >= NOW() - INTERVAL '7 days') AS resolved_last_7d,
                AVG(EXTRACT(EPOCH FROM (resolved_at - created_at)) / 3600)
                    FILTER (WHERE resolved_at IS NOT NULL)                 AS avg_resolution_hours
            FROM tickets
            WHERE product_id = $1
        }, $product->{id})->hash;

        my $report = {
            product_id   => $product->{id},
            product_name => $product->{name},
            period       => '7d',
            stats        => $stats,
        };

        Stega::Job::SendWelcomeNotification::_publish_notification($app, 'report.weekly_ready', $report);

        push @reports, $report;
    }

    $job->finish({ reports_generated => scalar @reports });
}

1;

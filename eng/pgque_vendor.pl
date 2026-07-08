#!/usr/bin/env perl
# eng/pgque_vendor.pl — gerencia a cópia vendorizada do PgQue em vendor/pgque/
#
# Ferramenta de apoio ao desenvolvimento (ADR-013) — nunca roda no build da
# imagem Docker nem em produção; o runtime e o CI só leem vendor/pgque/pgque.sql
# já commitado (ver eng/bootstrap_pgque.pl). Este é o único ponto do repositório
# que fala com o GitHub do projeto original (github.com/NikolayS/PgQue), e só
# quando um desenvolvedor invoca um dos subcomandos abaixo.
#
# vendor/pgque/SOURCE.json é a fonte de verdade sobre o que está vendorizado
# (tag, commit resolvido daquela tag e checksum SHA-256 de cada arquivo) —
# nunca edite esse arquivo à mão, ele é reescrito por 'update'.
#
# Uso:
#   carton exec perl eng/pgque_vendor.pl status
#   carton exec perl eng/pgque_vendor.pl list
#   carton exec perl eng/pgque_vendor.pl update <tag>
#   carton exec perl eng/pgque_vendor.pl diff [tag]
#
# 'diff' sem tag compara contra a tag gravada em SOURCE.json — é o caso de uso
# de validação de integridade (arquivo local corrompido/editado à mão diverge
# do que o GitHub tem naquela mesma tag).
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
$| = 1;

use FindBin;
use Mojo::UserAgent;
use Mojo::JSON  qw(decode_json);
use Mojo::File  qw(path);
use Digest::SHA qw(sha256_hex);
use File::Temp  qw();
use POSIX       qw(strftime);

use constant {
    REPO      => 'NikolayS/PgQue',
    API_BASE  => 'https://api.github.com/repos/NikolayS/PgQue',
    RAW_BASE  => 'https://raw.githubusercontent.com/NikolayS/PgQue',
    SQL_PATH  => 'sql/pgque.sql',
};

my $vendor_dir     = path("$FindBin::Bin/../vendor/pgque");
my $manifest_path  = $vendor_dir->child('SOURCE.json');

# nome local => caminho no repositório do PgQue; NOTICE é opcional (algumas
# tags antigas não têm), pgque.sql e LICENSE são obrigatórios.
my %TARGETS = (
    'pgque.sql' => SQL_PATH,
    'LICENSE'   => 'LICENSE',
    'NOTICE'    => 'NOTICE',
);

my $ua = Mojo::UserAgent->new;
$ua->connect_timeout(10)->request_timeout(30);

my $cmd = shift @ARGV // 'status';

if    ($cmd eq 'status') { cmd_status() }
elsif ($cmd eq 'list')   { cmd_list() }
elsif ($cmd eq 'update') { cmd_update(shift(@ARGV) // die "Uso: eng/pgque_vendor.pl update <tag>\n") }
elsif ($cmd eq 'diff')   { cmd_diff(shift @ARGV) }
else {
    die "Subcomando desconhecido: '$cmd'\n"
      . "Uso: eng/pgque_vendor.pl status|list|update <tag>|diff [tag]\n";
}

sub cmd_status {
    my $m = _load_manifest();
    unless ($m) {
        say "Nenhum vendor/pgque/SOURCE.json encontrado.";
        say "Rode: carton exec perl eng/pgque_vendor.pl update <tag>";
        return;
    }

    say "Repositório: $m->{repo}";
    say "Tag atual:   $m->{tag}";
    say "Commit:      $m->{commit}";
    say "Baixado em:  $m->{downloaded_at}";
    say '';
    say 'Integridade local (checksum gravado em SOURCE.json vs. arquivo em disco):';

    my $all_ok = 1;
    for my $name (sort keys %{ $m->{files} }) {
        my $file = $vendor_dir->child($name);
        my $status;
        if (!-f $file) {
            $status  = 'AUSENTE';
            $all_ok  = 0;
        }
        else {
            my $actual = 'sha256:' . sha256_hex($file->slurp);
            $status = $actual eq $m->{files}{$name} ? 'OK' : 'DIVERGENTE';
            $all_ok = 0 if $status ne 'OK';
        }
        printf "  %-12s %s\n", $name, $status;
    }

    if ($all_ok) {
        say "\nTudo consistente.";
    }
    else {
        say "\nATENÇÃO: use 'diff' para comparar contra o GitHub, ou 'update <tag>' para revendorizar.";
        exit 1;
    }
}

sub cmd_list {
    my $tags    = _api_get('/tags?per_page=100');
    my $m       = _load_manifest();
    my $current = $m ? $m->{tag} : undef;

    say 'Tags disponíveis em ' . REPO . ':';
    say '';
    for my $t (@$tags) {
        my $marker = (defined $current && $t->{name} eq $current) ? '*' : ' ';
        say "  $marker $t->{name}";
    }
    say '';
    say $current ? '* = vendorizada atualmente' : '(nenhuma tag vendorizada ainda — rode "update <tag>")';
}

sub cmd_update {
    my $tag = shift;

    say "Resolvendo tag '$tag'...";
    my $sha = _resolve_commit($tag);
    say "  commit: $sha";

    my %checksums;
    for my $local_name (sort keys %TARGETS) {
        my $remote_path = $TARGETS{$local_name};
        say "Baixando $remote_path...";
        my ($content, $code) = _fetch_raw($sha, $remote_path);

        if (!defined $content) {
            if ($local_name eq 'NOTICE' && $code == 404) {
                say '  NOTICE não existe nesta tag — ignorando (nem toda tag antiga tem um).';
                next;
            }
            die "Falha ao baixar $remote_path na tag $tag (HTTP $code)\n";
        }

        $vendor_dir->child($local_name)->spurt($content);
        $checksums{$local_name} = 'sha256:' . sha256_hex($content);
        say '  gravado em vendor/pgque/' . $local_name . ' (' . length($content) . ' bytes)';
    }

    _write_manifest({
        repo          => REPO,
        tag           => $tag,
        commit        => $sha,
        downloaded_at => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
        files         => \%checksums,
    });

    say '';
    say "vendor/pgque/ atualizado para $tag (commit " . substr($sha, 0, 12) . ').';
    say "Revise 'git diff vendor/pgque/' antes de commitar — em especial pgque.sql,";
    say 'e o changelog/docs/upgrading.md do PgQue para mudanças de API que quebrem compatibilidade.';
}

sub cmd_diff {
    my $tag = shift;
    my $m   = _load_manifest();

    if (!defined $tag) {
        die "Nenhuma tag informada e vendor/pgque/SOURCE.json não existe — rode\n"
          . "'update <tag>' primeiro, ou informe uma tag: eng/pgque_vendor.pl diff <tag>\n"
          unless $m;
        $tag = $m->{tag};
        say "Nenhuma tag informada — comparando contra a tag vendorizada atualmente ($tag).";
    }

    say "Resolvendo tag '$tag'...";
    my $sha = _resolve_commit($tag);

    my ($content, $code) = _fetch_raw($sha, SQL_PATH);
    die 'Falha ao baixar ' . SQL_PATH . " na tag $tag (HTTP $code)\n" unless defined $content;

    my $tmpdir      = File::Temp->newdir;
    my $remote_file = path($tmpdir)->child("pgque.sql\@$tag");
    $remote_file->spurt($content);

    my $local_file = $vendor_dir->child('pgque.sql');

    say '';
    say "Comparando vendor/pgque/pgque.sql (local) x $tag (commit " . substr($sha, 0, 12) . ", GitHub):";
    say '';

    my $rc = system('git', 'diff', '--no-index', '--', "$local_file", "$remote_file");
    die "Não foi possível executar 'git' — confirme que está no PATH.\n" if $rc == -1;

    my $exit_code = $rc >> 8;
    if ($exit_code == 0) {
        say "✔ Idêntico à tag $tag no GitHub.";
    }
    elsif ($exit_code == 1) {
        say "⚠ Diferenças encontradas em relação à tag $tag no GitHub (ver acima).";
    }
    else {
        die "git diff terminou com código inesperado: $exit_code\n";
    }
}

sub _load_manifest {
    return undef unless -f $manifest_path;
    return decode_json($manifest_path->slurp);
}

sub _write_manifest {
    my $data = shift;

    my @file_lines = map {
        qq(    "$_": "$data->{files}{$_}")
    } sort keys %{ $data->{files} };

    my $json = sprintf <<'JSON', $data->{repo}, $data->{tag}, $data->{commit}, $data->{downloaded_at}, join(",\n", @file_lines);
{
  "repo": "%s",
  "tag": "%s",
  "commit": "%s",
  "downloaded_at": "%s",
  "files": {
%s
  }
}
JSON

    $manifest_path->spurt($json);
}

sub _resolve_commit {
    my $tag  = shift;
    my $data = _api_get("/commits/$tag");
    return $data->{sha} // die "Não foi possível resolver a tag '$tag' para um commit\n";
}

sub _fetch_raw {
    my ($sha, $path) = @_;
    my $tx  = $ua->get(RAW_BASE . "/$sha/$path");
    my $res = $tx->result;
    return (undef, $res->code) unless $res->is_success;
    return ($res->body, $res->code);
}

sub _api_get {
    my $path = shift;

    my %headers = (
        'Accept'     => 'application/vnd.github+json',
        'User-Agent' => 'crystallized-perl-stega-eng-pgque-vendor',
    );
    $headers{Authorization} = "Bearer $ENV{GITHUB_TOKEN}" if $ENV{GITHUB_TOKEN};

    my $tx  = $ua->get(API_BASE . $path => \%headers);
    my $res = $tx->result;
    die 'GitHub API GET ' . $path . ' falhou: ' . $res->code . ' ' . ($res->message // '') . "\n"
      . ($res->body // '') . "\n"
      unless $res->is_success;

    return decode_json($res->body);
}

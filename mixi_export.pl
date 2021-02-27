#!/usr/bin/perl
use 5.8.1;
my $script_char  = 'UTF-8';
my $last_update  = '2019.05.30';
my $last_update_year = 2019;
#-------------------------------------------------------------------------------
my $DEBUG = 0;
my $FORK  = 0;
my $STOP_GZIP = 0;
my $IsWindows = ($^O eq 'MSWin32');
my $BufSize = 0x100000;
#-------------------------------------------------------------------------------
# mixi export
#                          Copyright (C)2006-2018 nabe@abk / E-mail:nabe@abk
#-------------------------------------------------------------------------------
# This program Lisenced under GPL3
use strict;
use Fcntl;	# for sysopen
use Time::Local;
#-------------------------------------------------------------------------------
# for PAR::Packer
#-------------------------------------------------------------------------------
use Socket;
use Encode;
use Encode::Guess qw(euc-jp shiftjis iso-2022-jp);
use Encode::JP;
use Encode::Unicode;
use Encode::Locale;
use Net::SSLeay;

###############################################################################
# ■変数初期化
###############################################################################
my $log_dir    = 'log2/';
my $for_adiary = 1;		# adiary向けの出力（0→はてな向け）
my $get_image  = 1;		# 元画像のURLを取得
my $parser     = 'simple_br';	# パーサー

my $qr_imgsrv = qr! src="(https?://[\w\-\.]*\.img\.mixi\.jp/[\w/]*\.(?:jpg|jpeg|gif|png))!i;

my $proxy       = 1;		# proxy型で動作する
my $bind_port   = 8888;		# bindするポート
my $get_mixi    = 1;		# mixi からデータを取得する
my $mixi_charset= 'EUC-JP';	# 入力文字コード (mixi)
my $out_charset = 'UTF-8';	# 出力文字コード
my $output_file = 'adiary.xml';	# 出力するファイル
my $sleep =  2;			# sleep する秒数
my $retry =  30;		# retry 回数（総計）
my $agent = Satsuki::Base::HTTP->new();
$agent->{http_agent} = 'Mozilla/5.0 (compatible; MSIE 11.0; Windows NT 6.1; WOW64; Trident/6.0)';
$agent->cookie_on();

my $message_url = 'https://adiary.org/download/tools/message.html';

my $EXTRA_UTF8_PATCH = 1;	# UTF-8変換表問題にパッチする

my $SelectTimeout = ($IsWindows ? 0.01 : undef);

###############################################################################
my $term_charset = 'UTF-8';
my $lang = $ENV{LANG};
if ($lang =~ /euc.*/i)    { $term_charset='EUC-JP'; }
if ($lang =~ /shift.*jis/i || $lang =~ /sjis/i) { $term_charset='Shift_JIS'; }
if ($IsWindows) {
	$term_charset = $Encode::Locale::ENCODING_CONSOLE_OUT;
}

###############################################################################
# ●引数解析
###############################################################################
my @ary = @ARGV;
my $help;
while(@ary) {
	my $key = shift(@ary);
	if (substr($key, 0, 1) ne '-') { $output_file = $key; next; }
	$key = substr($key, 1);
	# 引数なしオブション
	if ($key eq 'h')  { $help    =1; next; }
	if ($key eq '?')  { $help    =1; next; }
	if ($key eq 'g')  { $get_mixi=1; next; }
	if ($key eq 'n')  { $get_mixi=0; next; }
	if ($key eq 'f')  { $FORK   = 1; next; }
	if ($key eq 'd')  { $DEBUG  = 1; next; }
	if ($key eq 'x')  { $proxy  = 0; next; }
	if ($key =~ /s(\d+)/) { $sleep=$1; next; }
	# 引数ありオブション
	my $val = shift(@ary);
	if (!defined $val) { next; }
	if ($key eq 'c') { $lang  =$val; next; }
	if ($key eq 'p') { $bind_port  = int($val); next; }
	if ($key eq 's') { $sleep      = int($val); next; }
	if ($key eq 'r') { $retry      = int($val); next; }
	if ($key eq 'l') { $log_dir    =$val; next; }
	if ($key eq 'i') { $get_image  =$val; next; }
}

&myprint("\nmixi export \"Ver-${last_update}\" / (C)2006-$last_update_year nabe\@abk, Licensed under GPLv3\n\n");
if ($help) {
	&myprint(<<HELP);
Usage: $0 [options] [output_xml_file]
Available options are:
  -p port	接続を受けるポート番号を指定します（default:8888）
  -c charset	画面出力時の文字コードを指定します
  -g		mixi に接続しログを取得します (default)
  -n		mixi に接続せずに、セーブされたログを処理します
  -s sec	sleepする時間を指定します（単位：秒）(default:3)
  -l log_dir	ログを保存するディレクトリを指定します
  -i {1|0}	1:元画像ファイルのURLを取得します(default) 0:元画像は無視
  -f		forkで処理します。高速ですが、EXE版で動作しません。
  -d            デバッグモードに設定します
  -x            従来のid/pass入力でログインに挑戦（失敗します）
  -\?|-h		このヘルプを表示します
HELP
	exit(0);
}

###############################################################################
# ●初期化処理
###############################################################################
my $now = &get_timehash();

if (substr($log_dir, -1) ne '/') { $log_dir .= '/'; }
if (!-w $log_dir && !mkdir($log_dir)) {
	&error("ログディレクトリに書き込めません : $log_dir");
}
if ($sleep<1)      { $sleep =  1; }
if ($retry<0)      { $retry =  0; }
if ($retry>99)     { $retry = 99; }

$DEBUG && print "term charset: $term_charset, " . ($FORK ? 'fork' : 'threads') . " mode\n";

&myprint(<<TEXT);
ログディレクトリ : $log_dir
出力ファイル     : $output_file
Listen Port      : $bind_port

TEXT

######################################################################
# ■mixi からデータを取得
######################################################################
if ($get_mixi) {
#---------------------------------------------------------------------
# ●ログイン用データの取得
#---------------------------------------------------------------------
if ($proxy) {
	my $srv = new HTTP::SimpleProxy( $bind_port );
	if (!ref($srv)) {
		&error("Port $bind_port の bind に失敗しました。");
	}

	$srv->set_filter(sub {
		my ($method, $host, $path, $header, $body) = @_;
		if ($path =~ m|^/\?stop$|) {
			$srv->down('proxy_down');
			return;
		}

		if ($host eq 'mixi.jp') {
			if ($path =~ m|^/\w+\.pl| && $path !~ m|^/logout\.pl|) {
				my $data = join('', @$header);
				$srv->down($data);
				return "HTTP/1.1 303 See Other\r\nLocation: $message_url\r\nConnection: close\r\n\r\n";
			}
		}
		return;
	});

	&myprint("■ Proxy を 127.0.0.1:$bind_port 等に設定し、ブラウザからmixiにログインしてください。\n");
	&myprint("■ ログイン後に処理を開始します。\n\n");

	my $data = $FORK ? $srv->main_fork(5) : $srv->main(5);	# blocking

	if ($data eq 'proxy_down') {
		&myprint("Proxy Down\n");
		exit(1);
	}

	#-------------------------------------------------------------
	# セッション情報取得
	#-------------------------------------------------------------
	my @ary = split("\r\n", $data);
	my $cookie;
	foreach(@ary) {
		if ($_ =~ /^User-Agent: (.*)/i) {
			$agent->{http_agent} = $1;
			next;
		}
		if ($_ =~ /Cookie: (.*)/i) {
			$cookie = $1;
		}
	}
	if ($cookie eq '') {
		&myprint("セッション情報が見つかりません。\n");
		exit(2);
	}
	my $h = $agent->{cookie};
	foreach(split(";", $cookie)) {
		if ($_ !~ /(\w+)=([-\w]+)/)  { next; }
		if (substr($1,0,2) eq '_g') { next; }	# google analytics

		$h->{"mixi.jp;$1"} = { path => '/', name => $1, value => $2 };
	}

#---------------------------------------------------------------------
# ●ログイン処理
#---------------------------------------------------------------------
} else {
	my $post_key;
	{
		my $top = &get('https://mixi.jp/');
		if ($top !~ /class="PORTAL_loginForm /) {
			print $top;
			&error('mixiに接続できません');
		}
		if ($top =~ /<(input[^>]*name\s*=\s*"post_key"[^>]*)>/) {
			my $inp = $1;
			if ($inp =~ /value\s*=\s*"(\w+)"/) {
				$post_key = $1;
			}
		}
	}
	#---------------------------------------------------------
	# ●ID/PASS
	#---------------------------------------------------------
	my $mail;
	my $pass;
	if ($mail eq '') {
		print "login e-mail : ";
		$mail = <STDIN>;
		chomp($mail);
	}
	if ($pass eq '') {
		print "login password : ";
		$pass = <STDIN>;
		chomp($pass);
	}
	#---------------------------------------------------------
	# ●ログイン処理
	#---------------------------------------------------------
	{
		my %form;
		$form{next_url} = '/home.pl';
		$form{email}    = $mail;
		$form{password} = $pass;
		$form{post_key} = $post_key;
		$form{postkey} = '';
		my $res = &post('https://mixi.jp/login.pl?from=login1', \%form);

		# ログインできたか確認。
		if ($res !~ /http-equiv="refresh"/) {
			&error('ログイン失敗');
		}
	}
}

#---------------------------------------------------------------------
# ●日記リスト取得
#---------------------------------------------------------------------
my @yyyymm;
my $owner_id;
{
	my $res = &get('http://mixi.jp/list_diary.pl');
	if ($res !~ /view_diary\.pl\?.*?owner_id=(\d+)/) {
		&error('自分自身の owner_id 取得に失敗しました（ログイン失敗？）');
	}
	$owner_id = $1;

	if ($res !~ m|<div\sclass="diaryHistory">.*?<dl>(.*?)</dl>|s) {
		&error('日記リストの取得に失敗しました');
	}
	$res = $1;
	$res =~ s/\?year=(\d\d\d\d)&month=(\d+)/push(@yyyymm, $1 . substr($2+100,-2)), ''/eg;
}
#---------------------------------------------------------------------
# ●ログデータを取得
#---------------------------------------------------------------------
my $get_border = 0;
my %years;
@yyyymm = sort { $b <=> $a } @yyyymm;
foreach my $yyyymm (@yyyymm) {
	my $year = substr($yyyymm, 0, 4);
	my $mon  = substr($yyyymm, 4, 2);
	my $int_mon = int($mon);
	if (($yyyymm*100+99) < $get_border) { last; }
	&myprint("■$year年$mon月を処理\n");

	my @key_list;
	my $page='';
	my $page_num = 1;
	while(1) {
		sleep( $sleep );
		my $res = &get_auto_retry("http://mixi.jp/list_diary.pl?year=$year&month=$int_mon$page");
		# <a href="edit_diary.pl?id=123456789">編集する</a></span></dt>
		# <dd>2006年01月21日02:11<img src="003.gif" alt="友人まで公開" width="73" height="14" />
		$res =~ s
			|<a\s+href="[^\"]*/?edit_diary\.pl\?id=(\d+)[^\"]*".*?<dd[^>]*>\d\d\d\d[^\d]+\d\d[^\d]+(\d\d)[^\d]+\d\d:\d\d<img|
			push(@key_list, {yyyymmdd => int("$year$mon$2"), key => $1}), ''
		|esg;

		# 次のページがある？
		#	<div class="pageNavigation01 bottom"><div class="pageList03"><ul><li rel="__display">1件～30件を表示</li>
		#	<li rel="__next"><a href="/list_diary.pl?page=2&month=8&id=123456789&year=2017">次を表示</a></li></ul></div></div>

		my $flag=1;
		while ($res =~ m!<a href="[^\"]*/?list_diary\.pl[^\"\s>]*?page=(\d+)[^\"\s>]*"!gi) {
			if ($page_num >= $1) { next; }
			$page = '&page=' . $1;
			$page_num = $1;
			$flag=0; last;
		}
		if ($flag) { last; }
	}

	# ディレクトリ確認
	my $dir = "$log_dir$yyyymm/";
	if (@key_list && !-w $dir && !mkdir($dir)) {
		&error("ディレクトリに書き込めません : $dir");
	}

	foreach(@key_list) {
		my $key  = $_->{key};
		my $ymd  = $_->{yyyymmdd};
		my $year = substr($ymd, 0, 4);
		my $mon  = substr($ymd, 4, 2);
		my $day  = substr($ymd, 6, 2);
		my $file = "$dir$year-$mon-${day}_$key\.html";
		if (-e $file) {		# 取得するファイルが存在する
			if ($ymd < $get_border) {	# 境界日より前は取得しない
				next;
			} elsif (! $get_border) {		# 境界日が未決定
				if ($mon <= 1) { $mon=12; $year--; } else { $mon--; }
				$get_border = $year . sprintf("%02d", $mon) . $day;
				&myprint("--> 取得済ログを発見。１ヶ月前の${year}年${mon}月${day}日までを再取得対象にします。\n");
			}
		}
		sleep( $sleep );
		my $data = &get_auto_retry("http://mixi.jp/view_diary.pl?id=$key&owner_id=$owner_id&full=1");
		print "http://mixi.jp/view_diary.pl?id=$key&owner_id=$owner_id&full=1\n";
		#
		# 画像ファイルの処理
		#
		if ($get_image) {
			# <td><a onClick="MM_openBrWindow('/show_diary_picture.pl?owner_id=111&id=222&number=333','pict','***');">
			# <img src="http://classic-imagecluster.img.mixi.jp/p/fa7c8270c/58f45a33/diary/104410_32s.jpg" alt="" /></a></td>
			$data =~ s{<a\s[^>]*?\sonclick=[^>]*?'(/show_diary_picture\.pl\?[^']*)[^>]*>}{
				my $url = 'http://mixi.jp' . $1;
				my $img = &get_auto_retry($url);
				if ($img =~ m/$qr_imgsrv/) {
					$url = $1;
				}
				"<a href=\"$url\">";
			}ieg;
			$data =~ s{(<img\s[^>]*?\sclass="photoThumbnail"\s[^>]*?\ssrc="([^\"]*)"[^>]*>)}{
				my $tag = $1;
				my $url = $2;
				if ($url =~ m|\.img\.mixi\.jp/[\w\/]*?/(\d+)_(\d+)_(\d+)|) {
					# http://photo.mixi.jp/view_photo.pl?photo_id=1111&owner_id=222
					my $imgurl = "http://photo.mixi.jp/view_photo.pl?photo_id=$2&owner_id=$1";
					my $img = &get_auto_retry($imgurl);
					if ($img =~ m|<p class="photo">(.*?)</p>|is) {
						$img = $1;
						if ($img =~ m/$qr_imgsrv/) {
							print "$1\n";
							$tag = "<a href=\"$1\">$tag</a>";
						}
					}
				}
				$tag;
			}ieg;
			# <div class="largePhoto"> があると、ブラウザでうまく表示しない問題
			$data =~ s|(<div[^>]*)class="largePhoto"|${1}class="_largePhoto"|g;
		}
		&fwrite_lines($file, $data);
		# print "  save to file '$file'\n";
	}
}
#---------------------------------------------------------------------
} else {
	&myprint("ディスクに保存されたログから処理を開始します。\n");
}
######################################################################
# ■ログデータからエクスポートデータを作成
######################################################################
#---------------------------------------------------------------------
# ●ログデータを解析
#---------------------------------------------------------------------
my @days;
my $dirs = &search_files($log_dir, '', 1);
$dirs = [ sort {$a <=> $b} @$dirs ];
foreach my $_dir (@$dirs) {
	if ($_dir ne '.' && $_dir !~ /\d\d\d\d\d\d/) { next; }
	my $dir = "$log_dir$_dir/";
	# print "open dir '$dir'\n";

	my $files = &search_files($dir, '.html', 1);
	$files = [ sort {$a cmp $b} @$files ];
	foreach(@$files) {
		my $file = "$dir/$_";
		my $data = join('', @{ &fread_lines( $file ) });
		# for backup mixi log data
		if ($data =~ /charset=Shift_JIS/) {
			&from_to(\$data, 'Shift_JIS', $mixi_charset); 
		}
		# 改行コード統一
		$data =~ s/\r\n|\r/\n/g;
		if ($data !~ /<div class="viewDiaryBox">(.*?)<\/form>/s) {
			if ($dir ne '.') {
				unlink( $file );
				&myprint("未知のログデータです : $file [delete]\n");
			} else {
				&myprint("未知のログデータです : $file\n");
			}
			next;
		}
		$data = $1;
		# コメントを取り出す
		my @comments_data;
		$data =~ s|<dl\s*class="comment">(.*?</dd>)\s*\n</dl>\s*\n|push(@comments_data, $1), ''|seg;
		#-----------------------------------------------------
		# 本文の解析
		#-----------------------------------------------------
		my %day;
		# file
		$day{file} = "$_dir/$_";

		# 日付
		# <dd class="date">2006年01月27日02:50<img src="_003.gif" alt="友人まで公開" width="73" height="14" />
		if ($data =~ m|<dd[^>]*>(\d\d\d\d)[^\d][^\d](\d\d)[^\d][^\d](\d\d)[^\d][^\d](\d\d):(\d\d)|) {
			$day{year} = $1;
			$day{mon}  = sprintf("%02d", $2);
			$day{day}  = sprintf("%02d", $3);
			$day{hour} = $4;
			$day{min}  = $5;
			$day{tm}   = timelocal(0, $5, $4, $3, $2-1, $1-1900);
		}
		# 非公開？
		# <dd class="date"><img src="http://img.mixi.net/img/basic/icon/pub_level_004.gif" alt="非公開" width="73" height="14" />
		$day{enable} = !($data =~ /<dd[^>]*>\d\d\d\d[^<]*<img\s+[^>]*alt="\xC8\xF3\xB8\xF8\xB3\xAB"/i);

		# タイトル
		if ($data =~ /<dt>([^<]*)<span><a href="[^"]*?edit_diary\.pl/) {
			$day{title} = $1;
		}

		# diaryPhoto
		# <div class="diaryPhoto">
		if ($data =~ m|<div\s+[^>]*class="diaryPhoto"(.*?)</div>|si) {
			my $html = $1;
			# <td><a onClick="MM_openBrWindow('/show_diary_picture.pl?owner_id=111&id=222&number=333','pict','***');">
			# <img src="http://classic-imagecluster.img.mixi.jp/p/fa7c8270c/58f45a33/diary/104410_32s.jpg" alt="" /></a></td>
			my @img;
			my @url;
			$html =~ s|(<a\s[^>]*>.*?</a>)|push(@img, $1)|eg;
			if (@img) {
				$day{photo} = '<div class="diaryPhoto">' . join(' ', @img) . "</div>\n";
			}
		}

		# 本文
		if ($data =~ m|<div id="diary_body"[^>]*>(.*?)<br /></div>\n|s) {
			my $log = $1;
			$log =~ s/\n<br.*?>|<br.*?>\n|<br.*?>/\n/g;
			while(substr($log, 0, 1) eq "\n") { $log=substr($log, 1); }
			while(substr($log,   -1) eq "\n") { chop($log); }
			$day{body} = $log;
		}
		my $title = $day{title};
		&from_to(\$title, $mixi_charset, $term_charset);
		print "$day{year}/$day{mon}/$day{day} $day{hour}:$day{min} - $title\n";
		#-----------------------------------------------------
		# コメントの解析処理
		#-----------------------------------------------------
		my @comments;
		foreach(@comments_data) {
			my %h;
			# 日付
			# <dt><a href="show_friend.pl?id=XXXX">誰か</a><span class="date">2008年12月04日&nbsp;19:20</span>
			if ($_ !~ /(\d\d\d\d)[^\d][^\d](\d\d)[^\d][^\d](\d\d)[^\d][^\d].*?(\d\d):(\d\d)/) { next; }
			$h{tm} = timelocal(0, $5, $4, $3, $2-1, $1-1900);
			my $date = "$1/$2/$3 $4:$5";
			# 名前
			if ($_ =~ /<a href="(?:http:\/\/mixi\.jp\/|)show_friend\.pl\?id=\d+">(.*?)<\/a>/) {
				$h{name} = $1;
			}
			# 本文
			if ($_ =~ m|<dd>[\n\s]*(.*?)</dd>|s) {
				my $log = $1;
				$log =~ s|<br />|<br>|ig;
				$log =~ s/[\r\n]//g;
				$h{body} = $log;
			}
			
			my $name = $h{name};
			&from_to(\$name, $mixi_charset, $term_charset);
			print "\tcomment $date by $name\n";
			push(@comments, \%h);
		}
		$day{comments} = \@comments;
		push(@days, \%day);
	}
}

#---------------------------------------------------------------------
# ●ログデータの出力書式を整える
#---------------------------------------------------------------------
my @save_data;
my %ymd;
push(@save_data, <<XML_HEADER);
<?xml version="1.0" encoding="$out_charset"?>
<diary>
XML_HEADER

foreach my $day (@days) {
	my @out;
	my $title  = $day->{title};
	my $body   = $day->{body};
	my $enable = $day->{enable} ? 1 : 0;
	&tag_escape($title, $body);
	push(@out, <<DIARY);
<day date="$day->{year}-$day->{mon}-$day->{day}" title="$title" enable="$enable">
<attributes tm="$day->{tm}" parser="$parser" adiary="1"></attributes>
<body>$day->{photo}$body</body>
DIARY
	#--------------------------------------------------
	# コメント
	#--------------------------------------------------
	my $comments = $day->{comments};
	if (@$comments) { push(@out, "<comments>\n"); }
	foreach(@$comments) {
		&tag_escape($_->{name}, $_->{body});
		push(@out, <<COMMENT);
<comment>
<username>$_->{name}</username>
<timestamp>$_->{tm}</timestamp>
<body>$_->{body}</body>
</comment>
COMMENT
	}
	if (@$comments) { push(@out, "</comments>\n"); }
	#--------------------------------------------------
	# 文字コード変換をして出力
	#--------------------------------------------------
	{
		push(@out, "</day>\n");
		my $out = join('', @out);
		&from_to(\$out, $mixi_charset, $out_charset);
		push(@save_data, $out);
	}
	#--------------------------------------------------
	# index.html用データ
	#--------------------------------------------------
	my $year = $ymd{$day->{year}}   ||= {};
	my $a2   = $year->{$day->{mon}} ||= [];
	&from_to(\$title, $mixi_charset, $out_charset);

	push(@$a2, <<HTML);
			<li>$day->{year}/$day->{mon}/$day->{day} <a href="$day->{file}">$title</a></li>
HTML
}
push(@save_data, "</diary>\n");
#---------------------------------------------------------------------
# ●ファイルに出力
#---------------------------------------------------------------------
&myprint("\n結果を $output_file に保存します。\n");
&fwrite_lines( $output_file, \@save_data );

#---------------------------------------------------------------------
# ●index.html生成
#---------------------------------------------------------------------
&myprint("\nindex.htmlを保存します。\n");
my $list = "<body>\n";
foreach my $y (sort {$a <=> $b} keys(%ymd)) {
	my $yh = $ymd{$y};
	$list .= <<HTML;
<article>
	<h2>${y}年</h2>
	<div class="body">
HTML
	foreach my $m (sort {$a <=> $b} keys(%$yh)) {
		my $ary = $yh->{$m};
		$list .= "\t\t<h3>${y}年${m}月</h3>\n\t\t<ul>\n";
		$list .= join('', @$ary);
		$list .= "\t\t</ul>\n\n";
	}
	chomp($list);
	$list .= <<HTML;
	</div>
</article>

HTML
}
chomp($list);
$list .= "</body>\n";
#---------------------------------------------------------------------
{
	my ($sec,$min,$hour,$day,$mon,$year,$wday,$yday,$isdst) = localtime();
	my $ymd = sprintf("%d/%02d/%02d", $year+1900, $mon, $day);

	$list = <<HTML;
<h1>mixi export log - $ymd</h1>
<div class="main">
$list
</div>
HTML

}

#---------------------------------------------------------------------
my $lines = &fread_lines('mixi_export.html');
my $html  = join('', @$lines);
$html =~ s|<body>.*</body>|$list|s;
my $index_file = $log_dir . 'index.html';
&fwrite_lines( $index_file, $html );

#---------------------------------------------------------------------
&fwrite_lines( './log-data.html', <<HTML );
<!DOCTYPE html>
<html lang="ja">
<head>
	<script>location.href = "$index_file";</script>
	<title>goto index.html</title>
</head>
<body>
<a href="$index_file" style="font-size: 20pt;">$index_file</a>
</body></html>
HTML
#---------------------------------------------------------------------
exit(0);

###############################################################################
# ■サブルーチン
###############################################################################
#-------------------------------------------------------------------------------
# ●出力
#-------------------------------------------------------------------------------
sub myprint {
	my $str = join('', @_);
	Encode::from_to($str, $script_char, $term_charset);
	print $str
}

#-------------------------------------------------------------------------------
# ●URLからデータを取得
#-------------------------------------------------------------------------------
sub get {
	my ($url) = @_;
	print "Connect to : $url\n";
	my $res = $agent->get($url);
	if ($agent->{error_msg}) { &error($agent->{error_msg}); }

	return join('', @$res);
}
sub post {
	my ($url, $post_data) = @_;
	print "Connect to : $url\n";
	my $res = $agent->post($url, '', $post_data);
	if ($agent->{error_msg}) { &error($agent->{error_msg}); }

	return join('', @$res);
}
#-------------------------------------------------------------------------------
# ●リトライ付きの GET
#-------------------------------------------------------------------------------
sub get_auto_retry {
	my $data = &get(@_);
	while(index($data, 'http://mixi.jp/home.pl')<0
	  && $data !~ m| src="https?://[\w\-\.]*\.img\.mixi\.jp/|
	  && $retry>0)
	{
		print "$data\n";
		&myprint("Retry（残り $retry 回）\n"); $retry--;
		sleep( $sleep+5 );
		$data = &get(@_);
	}
	return $data;
}

#-------------------------------------------------------------------------------
# ●エラー処理
#-------------------------------------------------------------------------------
sub error {
	&myprint("Error : ", @_, "\n");
	exit(-1);
}
#-------------------------------------------------------------------------------
# ●時刻取得
#-------------------------------------------------------------------------------
sub get_timehash {
	my %h;
	( $h{sec},  $h{min},  $h{hour},
	  $h{_day}, $h{_mon}, $h{year},
	  $h{wday}, $h{yday}, $h{isdst}) = localtime($_[0] || time);
	$h{year} +=1900;
	$h{_mon} ++;
	$h{mon} = sprintf("%02d", $h{_mon});
	$h{day} = sprintf("%02d", $h{_day});
	return \%h;
}

#------------------------------------------------------------------------------
# ●ファイル：すべての行を読み込む
#------------------------------------------------------------------------------
# $array_ref = &fread_lines($file);
sub fread_lines {
	my ($file) = @_;
	my $fh;
	if ( !sysopen($fh, $file, O_RDONLY) ) { die("File can't read : $file"); }
	my @lines = <$fh>;
	close($fh);
	return \@lines;
}

#------------------------------------------------------------------------------
# ●すべての行をファイルに書き込む
#------------------------------------------------------------------------------
# &fwrite_lines($file, $array_ref);
sub fwrite_lines {
	my ($file, $lines) = @_;
	if (!ref($lines)) { $lines = [ $lines ]; }
	my $fh;
	if ( !sysopen($fh, $file, O_CREAT | O_WRONLY | O_TRUNC) ) { die("File can't write : $file"); }
	foreach(@$lines) {
		print $fh $_;
	}
	close($fh);
}

#------------------------------------------------------------------------------
# ●ファイルを検索する
#------------------------------------------------------------------------------
# search_files("directory name", "file extension", $dir_flag);
sub search_files {
	my ($dir, $file_ex, $dir_flag) = @_;
	my $fh;
	my $len = length($file_ex);
	my @filelist;
	opendir($fh, $dir) || return [];
	foreach(readdir($fh)) {
		if ($_ eq '.' || $_ eq '..' )  { next; }	# ./ ../ は無視
		if (!$dir_flag && -d "$dir$_") { next; }	# ディレクトリは無視
		if ($len) {	# 拡張子指定あり
			if (substr($_, -$len) ne $file_ex) { next; }	# 末尾であるか確認
		}
		push(@filelist, $_);
	}
	closedir($fh);
	return \@filelist;
}

#------------------------------------------------------------------------------
# ●タグのエスケープ
#------------------------------------------------------------------------------
sub tag_escape {
	foreach(@_) {
		$_ =~ s/&/&amp;/g;
		$_ =~ s/</&lt;/g;
		$_ =~ s/>/&gt;/g;
		$_ =~ s/"/&quot;/g;
	}
	return $_[0];
}

#------------------------------------------------------------------------------
# ●日本語変換
#------------------------------------------------------------------------------
sub from_to {
	# main start
	my ($str, $from, $to) = @_;
	if (ref($str) ne 'SCALAR') { my $s=$str; $str=\$s; }
	if ($$str =~ /^[\x00-\x0d\x10-\x1a\x1c-\x7e]*$/
	 || &get_Jcodename($from) eq &get_Jcodename($to) ) { return $$str; }
	# UTF-8パッチ
	if ($EXTRA_UTF8_PATCH && ($from eq '' || $from =~ /UTF.*8/i)) {
		$$str =~ s/\xEF\xBD\x9E/\xE3\x80\x9C/g;	# ? EFBD9E E3809C
		$$str =~ s/\xEF\xBC\x8D/\xE2\x88\x92/g;	# ‐ EFBC8D E28892
		$$str =~ s/\xE2\x88\xA5/\xE2\x80\x96/g;	# ? E288A5 E28096
	}
	# Encode
	if ($from =~ /UTF.*8/i) {	# from が UTF8 のとき
		Encode::_utf8_on($$str);
		eval { $$str = Encode::encode($to, $$str); };
	} else {
		eval { Encode::from_to($$str, $from, $to); };
	}
	# UTF-8パッチ
	if ($EXTRA_UTF8_PATCH && $to =~ /UTF.*8/i) {
		$$str =~ s/\xE3\x80\x9C/\xEF\xBD\x9E/g;	# ? E3809C EFBD9E
		$$str =~ s/\xE2\x88\x92/\xEF\xBC\x8D/g;	# ‐ E28892 EFBC8D
		$$str =~ s/\xE2\x80\x96/\xE2\x88\xA5/g;	# ? E28096 E288A5
	}
	return $$str;
}

#------------------------------------------------------------------------------
# ●文字コード名の正規化
#------------------------------------------------------------------------------
sub get_Jcodename {
	my ($code) = @_;
	if ($code =~ /utf.*8/i)   { return 'utf8'; }
	if ($code =~ /euc.*/i)    { return 'euc'; }
	if ($code =~ /shift.*jis/i || $code =~ /sjis/i) { return 'sjis'; }
	if ($code =~ /jis/i)      { return 'jis'; }
	if ($code =~ /2022\-jp/i) { return 'jis'; }
	return ;
}

#------------------------------------------------------------------------------
# ●httpsリクエスト
#------------------------------------------------------------------------------
sub https_req {
	my $method = shift;
	my $host   = shift;

	my ($page, $result, $headers);
	if ($method eq 'POST') {
		($page, $result, $headers) = Net::SSLeay::post_https3($host, 443, @_);
	} else {
		($page, $result, $headers) = Net::SSLeay::get_https3 ($host, 443, @_);
	}
	return ($page, $result, split("\r\n", $headers));
}

#------------------------------------------------------------------------------
# ●httpsリクエスト
#------------------------------------------------------------------------------
sub http_req {
	my $method = shift;
	my $host   = shift;
	my $path   = shift;
	my $header = shift;
	my $data   = shift;

	my $req = "$method $path HTTP/1.1\r\n";
	$req .= "$header\r\n\r\n$data";
	my $res = $agent->get_data($host, 80, $req);

	my $status = shift(@$res);
	$status =~ s/\r\n//;
	my @headers;
	while(@$res) {
		my $x = shift(@$res);
		$x =~ s/\r\n//;
		if ($x eq '') { last; }
		push(@headers, $x);
	}
	return (join('',@$res), $status, @headers);
}

###############################################################################
#------------------------------------------------------------------------------
# HTTP簡易サーバ
#------------------------------------------------------------------------------
package HTTP::SimpleProxy;
use Socket;
use Fcntl;
use POSIX;
use threads;
#------------------------------------------------------------------------------
sub new {
	my $self = bless({}, shift);
	my $port = shift || 8888;
	my $srv;

	socket($srv, PF_INET, SOCK_STREAM, 0)				|| return "socket failed: $!";
	setsockopt($srv, SOL_SOCKET, SO_REUSEADDR, pack("l", 1))	|| return "setsockopt failed: $!";
	bind($srv, sockaddr_in($port, INADDR_ANY))			|| return "bind port failed: $!";
	listen($srv, 1000)						|| return "listen failed: $!";

	$self->{srv}  = $srv;
	$self->{port} = $port;
	return $self;
}
#------------------------------------------------------------------------------
# ithreads版
#------------------------------------------------------------------------------
sub main {
	my $self = shift;
	my $dsec = shift || 1;
	my $srv  = $self->{srv};

	# create pipe
	my $pipe_r;
	my $pipe_w;
	# pipe($pipe_r, $pipe_w);
	socketpair($pipe_r, $pipe_w, AF_UNIX, SOCK_STREAM, PF_UNSPEC);
	$self->{pipe} = $pipe_w;
	$pipe_w->autoflush(1);

	my $rbits = '';
	&set_bit($rbits, $srv);
	&set_bit($rbits, $pipe_r);

	my $data;
	my $shutdown = 0;
	while(1) {
		$DEBUG && $shutdown && print "shutdown count = $dsec\n";
		if ($dsec <= 0) { last; }

		my $r = select(my $x = $rbits, undef, undef, 1.00);
		if (!$shutdown && &check_bit($x, $pipe_r)) {
			recv($pipe_r, $data, $BufSize, 0);
			if ($data ne '') {
				$DEBUG && print "go shutdown\n";
				$shutdown = 1;
				next;
			}
		}
		if (! &check_bit($x, $srv)) {
			$dsec -= $shutdown;	# proxy down count
			next;
		}

		# accept
		my $addr = accept(my $client, $srv);
		if (!$addr) { next; }

		my $thr = threads->create(\&accept_client, $self, $client, $addr);
		$thr->detach();
	}
	sleep(1);
	close($pipe_r);
	close($pipe_w);
	close($self->{srv});
	return $data;
}

#------------------------------------------------------------------------------
# fork版
#------------------------------------------------------------------------------
sub main_fork {
	my $self = shift;
	my $dsec = shift || 1;
	my $srv  = $self->{srv};

	# create pipe
	my $pipe_r;
	my $pipe_w;
	# pipe($pipe_r, $pipe_w);
	socketpair($pipe_r, $pipe_w, AF_UNIX, SOCK_STREAM, PF_UNSPEC);
	$self->{pipe} = $pipe_w;
	$pipe_w->autoflush(1);

	my $rbits = '';
	&set_bit($rbits, $srv);
	&set_bit($rbits, $pipe_r);

	my %pid;
	my $data;
	my $shutdown = 0;
	while(1) {
		$DEBUG && $shutdown && print "shutdown count = $dsec\n";
		if ($dsec <= 0) { last; }
		foreach(keys(%pid)) {
			my $r = waitpid($_, WNOHANG);
			if ($r < 0) {
				delete($pid{$_});
			}
		}

		my $r = select(my $x = $rbits, undef, undef, 1.00);
		if (!$shutdown && &check_bit($x, $pipe_r)) {
			recv($pipe_r, $data, $BufSize, 0);
			if ($data ne '') {
				$DEBUG && print "go shutdown\n";
				$shutdown = 1;
				next;
			}
		}
		if (! &check_bit($x, $srv)) {
			$dsec -= $shutdown;	# proxy down count
			next;
		}

		# fork
		my $pid = fork();
		if (!defined $pid) {
			die "Fork fail!!\n";
		}
		if (!$pid) {
			my $addr = accept(my $client, $srv);
			if ($addr) {
				$self->accept_client($client, $addr);
			}
			exit();
		}
		$pid{$pid} = 1;
	}
	sleep(1);
	close($pipe_r);
	close($pipe_w);

	foreach(keys(%pid)) {
		kill('KILL', $_);
	}
	close($self->{srv});
	return $data;
}

#------------------------------------------------------------------------------
sub down {
	my $self = shift;
	my $data = shift || '0';
	my $pipe = $self->{pipe};

	print $pipe $data;
	return ;
}

#------------------------------------------------------------------------------
sub accept_client {
	my $self   = shift;
	my $client = shift;
	my $addr   = shift;

	my($port, $ip_bin) = sockaddr_in($addr);
	my $ip   = inet_ntoa($ip_bin);
	binmode($client);

	# HTTPヘッダ解析
	my @header;
	my $c_len;

	while(1) {
		my $line = <$client>;
		if (!defined $line)  { return; }	# disconnect
		if ($line eq "\r\n") { last; }
		push(@header, $line);

		if ($line =~ /^Content-Length: (\d+)/i) {
			$c_len = $1;
		}
	}

	my $body;
	if ($c_len) {
		read($client, $body, $c_len);
	}

	# 各メソッドの処理
	my $req = shift(@header);
	$DEBUG && print "[$$] $req";

	my $method = ($req =~ /^(\w+)/) ? $1 : '';

	my $r;
	if ($method eq 'GET') {
		$r = $self->get($client, $req, \@header);
	} elsif ($method eq 'POST') {
		$r = $self->post($client, $req, \@header, $body);
	} elsif ($method eq 'HEAD') {
		$r = $self->head($client, $req, \@header);
	} elsif ($method eq 'CONNECT') {
		$r = $self->connect($client, $req, \@header);
	}
	close($client);

	# エラー処理
	if ($r) {
		print STDERR "$r\n";
	}
}

#------------------------------------------------------------------------------
sub post {
	return &get(@_);
}
sub head {
	return &get(@_);
}
sub get {
	my $self   = shift;
	my $client = shift;
	my $req    = shift;
	my $header = shift;
	my $body   = shift;

	if ($req !~ m!^(GET|POST|HEAD) http://([\.\w\-]+)(?::(\d+))?(/[^\s]*) ([^s*])!i) {
		$self->proxy_error($client);
		return "REQUEST Error : $req";
	}
	my $method = $1;
	my $host   = $2;
	my $port   = $3 || 80;
	my $path   = $4;

	# フィルター
	if ($self->{filter}) {
		my $r = &{$self->{filter}}($method, $host, $path, $header, $body);
		if ($r ne '') {
			print $client $r;
			return 0;
		}
	}

	my $agent = Satsuki::Base::HTTP->new();
	my $res   = $agent->get_data($host, $port, 
			"$method $path HTTP/1.1\r\n",
			&set_header(@$header), $body);

	foreach(@$res) {
		print $client $_;
	}
	return 0;
}

#------------------------------------------------------------------------------
sub connect {
	my $self   = shift;
	my $client = shift;
	my $req    = shift;
	my $header = shift;

	if ($req !~ m|^CONNECT ([\.\w\-]+)(?::(\d+))? ([^s*])|i) {
		return "REQUEST Error : $req";
	}
	my $host = $1;
	my $port = $2 || 443;

	my $agent = Satsuki::Base::HTTP->new();
	my $sock  = $agent->connect_host($host, $port);
	if (!$sock) {
		$self->proxy_error($client);
		return "Connection ERROR";
	}
	print $client "HTTP/1.0 200 Connection Established\r\n\r\n";
	binmode($client);	# buffer flush

	my $rbits = '';
	&set_bit($rbits, $client);
	&set_bit($rbits, $sock);

	while(1) {
		my $r = select(my $x = $rbits, undef, undef, $SelectTimeout);

		if (&check_bit($x, $client)) {
			my $data;
			recv($client, $data, $BufSize, 0);
			if ($data eq '') { last; }
			syswrite($sock, $data, length($data));
		}
		if (&check_bit($x, $sock)) {
			my $data;
			recv($sock, $data, $BufSize, 0);
			if ($data eq '') { last; }
			syswrite($client, $data, length($data));
		}
	}
	close($sock);
	return 0;
}

#------------------------------------------------------------------------------
sub proxy_error {
	my $self = shift;
	my $client = shift;

print $client <<'HTML';
HTTP/1.1 403 Proxy Error
Connection: close
Content-Type: text/html; charset=iso-8859-1

<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
<html><head>
<title>403 Proxy Error</title>
</head><body>
<h1>Proxy Error</h1>
</body></html>
HTML
	return;
}

#------------------------------------------------------------------------------
sub set_filter {
	my $self = shift;
	my $func = shift;
	$self->{filter} = $func;
}

#------------------------------------------------------------------------------
sub set_bit	{ vec($_[0], fileno($_[1]), 1) = 1; }
sub reset_bit	{ vec($_[0], fileno($_[1]), 1) = 0; }
sub check_bit   { vec($_[0], fileno($_[1]), 1); }

sub set_header {
	my @ary;
	foreach(@_) {
		if ($_ eq "\r\n") { last; }
		if ($_ =~ /^Connection:/i) { next; }
		if ($STOP_GZIP && $_ =~ /^Accept-Encoding:/i) { next; }
		push(@ary, $_);
	}
	push(@ary, "Connection: close\r\n\r\n");
	return @ary;
}

#------------------------------------------------------------------------------
sub set_non_blocking {	# DO NOT USE
	my $fh = shift;
	my $flags;
	if ($^O eq 'MSWin32') {
		ioctl($fh, 0x8004667e, 1);
		return ;
	}
 	fcntl($fh, Fcntl::F_GETFL, $flags);
	$flags |= &O_NONBLOCK;
	fcntl($fh, Fcntl::F_SETFL, $flags);
}

###############################################################################
###############################################################################
###############################################################################
#------------------------------------------------------------------------------
# HTTPモジュール
#						(C)2006-2013 nabe / nabe@abk
#------------------------------------------------------------------------------
# 簡易実装の HTTP モジュールです。本格的な使用には耐えません。
#
package Satsuki::Base::HTTP;
our $VERSION = '1.30';
#------------------------------------------------------------------------------
use Socket;
###############################################################################
# ■基本処理
###############################################################################
#------------------------------------------------------------------------------
# ●【コンストラクタ】
#------------------------------------------------------------------------------
sub new {
	my $self = bless({}, shift);
	my $ROBJ = shift;

	$self->{ROBJ}    = $ROBJ;
	$self->{cookie}  = {};	# 空の hash
	$self->{timeout} = 30;
	$self->{auto_redirect} = 1;	# リダイレクト処理を１回だけ追う
	if (defined $ROBJ) {
		$self->{http_agent} = "Satsuki-system $ROBJ->{VERSION} ";
	}
	$self->{http_agent} = "Simple HTTP agent $VERSION";
	$self->{use_cookie} = 0;
	return $self;
}
#------------------------------------------------------------------------------
# ●【デストラクタ】
#------------------------------------------------------------------------------
sub DESTROY {
}

###############################################################################
# ■メインルーチン
###############################################################################
#------------------------------------------------------------------------------
# ●ホストに対して処理する
#------------------------------------------------------------------------------
sub get_data {
	my $self = shift;
	my $host = shift;
	my $port = shift;

	my $socket = $self->connect_host($host, $port);
	if (!defined $socket) { return ; }
	my $res = $self->send_http_request($socket, $host, @_);
	if (!defined $res) { return ; }
	close($socket);

	return $res;
}

#------------------------------------------------------------------------------
# ●指定ホストに接続する
#------------------------------------------------------------------------------
sub connect_host {
	my ($self, $host, $port) = @_;

	my $ip_bin = inet_aton($host);		# IP 情報に変換
	if ($ip_bin eq '') {
		return $self->error(undef, "Can't find host '%s'", $host);
	}
	my $sockaddr = pack_sockaddr_in($port, $ip_bin);
	my $sh;
	if (! socket($sh, Socket::PF_INET(), Socket::SOCK_STREAM(), 0)) {
		return $self->error(undef, "Can't open socket");
	}
	{
		local $SIG{ALRM} = sub { close($sh); };
		alarm( $self->{timeout}+1 );
		my $r = connect($sh, $sockaddr);
		alarm(0);
		$r || return $self->error($sh, "Can't connect %s", $host);
	}

	binmode($sh);
	return $sh;
}

#------------------------------------------------------------------------------
# ●GET, POST, HEAD などを送り、データを受信する
#------------------------------------------------------------------------------
sub send_http_request {
	my $self   = shift;
	my $socket = shift;
	my $host   = shift;
	my $ROBJ   = $self->{ROBJ};
	{
		my $request = join('', @_);
		syswrite($socket, $request, length($request));
	}
	my @response;
	my $vec_in = '';
	vec($vec_in, fileno($socket), 1) = 1;
	my ($r, $timeout);
	{
		local $SIG{ALRM} = sub { close($socket); $timeout=1; };
		alarm( $self->{timeout}+1 );
		$r = select($vec_in, undef, undef, $self->{timeout});
		if (vec($vec_in, fileno($socket), 1) ) {
			@response = <$socket>;
		}
		alarm(0);
		close($socket);
	}
	if (! @response) {
		if (!$r || $timeout) {
			return $self->error($socket, "Connection timeout '%s' (timeout %d sec)", $host, $self->{timeout});
		}
		return $self->error($socket, "Connection closed by '%s'", $host);
	}

	$self->parse_status_line($response[0], $host);
	return \@response;
}

#-------------------------------------------------
# ●status lineの処理
#-------------------------------------------------
sub parse_status_line {
	my $self   = shift;
	my $status = int( (split(' ', shift))[1] );
	my $host   = shift;
	$self->{status} = $status;
	if ($status != 200 && ($status<301 || 304<$status)) {
		return $self->error(undef, "Error response from '%s' (status %d)", $host, $status);
	}
}

###############################################################################
# ■上位サービスルーチン
###############################################################################
# Cookie実装ポリシー
#	・expires は無視（すべてsession cookieとして処理）
#------------------------------------------------------------------------------
# ●cookieのon/off（デフォルト:off）
#------------------------------------------------------------------------------
sub cookie_on {
	my $self = shift;
	$self->{use_cookie} = 1;
}
sub cookie_off {
	my $self = shift;
	$self->{use_cookie} = 0;
}

#------------------------------------------------------------------------------
# ●指定したURLからGET/POSTし、中身データを返す
#------------------------------------------------------------------------------
#-----------------------------------------------------------
# GET/POSTとRedirect処理
#-----------------------------------------------------------
sub get {
	my $self = shift;
	return $self->request('GET',  @_);
}
sub post {
	my $self = shift;
	return $self->request('POST', @_);
}
sub request {
	my $self = shift;
	my $method = shift;
	my $url = shift;
	$self->{redirects} = 0;
	while (1) {
		my $r = $self->do_request($method, $url, @_);
		# 正常終了
		my $status = $self->{status};
		if (!$self->{location} || $status<301 || 303<$status || (++$self->{redirects}) > $self->{auto_redirect}) {
			return wantarray ? ($status, $self->{header}, $r) : $r;
		}
		# Redirect
		$url = $self->{location};
	}
}
#-----------------------------------------------------------
# リクエスト処理本体
#-----------------------------------------------------------
sub do_request {
	my $self = shift;
	my $ROBJ = $self->{ROBJ};

	my ($method, $url, $_header, $post_data) = @_;
	my $cookie = $self->{cookie};
	my $https = ($url =~ m|^https://|i);

	if ($url !~ m|^https?://([^/:]*)(:(\d+))?(.*)|) {
		return $self->error(undef, "URL format error '%s'", $url);
	}
	my $host = $1;
	my $port = $3 || ($https ? 443 : 80);
	my $path = $4 || '/';
	#----------------------------------------------------------------------
	# Cookieの処理
	#----------------------------------------------------------------------
	my $http_cookie;
	if ($self->{use_cookie}) {
		my @ary;
		while(my ($k,$v) = each(%$cookie)) {
			$k =~ /(.*);/;
			my $chost = $1;
			my $dom = $chost;
			$dom =~ s/^\.*/./;
			if ($chost eq $host || index($host, $dom)>0 ) {
			 	if ($v->{path} && index($path, $v->{path}) < 0) { next; }
			 	if ($v->{value} eq '') { next; }	# 空のcookieは無視
				push(@ary, "$v->{name}=$v->{value}");
			}
		}
		$http_cookie = join('; ', @ary);
		if ($http_cookie) { $http_cookie = "Cookie: $http_cookie\r\n"; }
	}

	#----------------------------------------------------------------------
	# ヘッダの初期処理
	#----------------------------------------------------------------------
	my %header;
	if (ref($_header) eq 'HASH') { %header = %$_header; }	# copy
	$header{Host} ||= $host;
	$header{'User-Agent'} ||= $self->{http_agent};

	#----------------------------------------------------------------------
	# POSTリクエスト
	#----------------------------------------------------------------------
	my $content;
	if ($method eq 'POST') {
		if (ref($post_data) eq 'HASH') {
			while(my ($k,$v) = each(%$post_data)) {
				$self->encode_uricom($k,$v);
				$content .= "$k=$v&";
			}
			chop($content);
		} else {
			$content = $post_data;
		}
		if (!$https) {
			$header{'Content-Length'} = length($content);
			$header{'Content-Type'} ||= 'application/x-www-form-urlencoded';
		}
	}

	#----------------------------------------------------------------------
	# ヘッダの構成初期処理
	#----------------------------------------------------------------------
	my $header;
	foreach(keys(%header)) {
		if ($_ eq '' || $_ =~ /[^\w\-]/) { next; }
		my $v = $header{$_};
		$v =~ s/^\s*//;
		$v =~ s/[\s\r\n]*$//;
		$header .= "$_: $v\r\n";
	}
	$header .= $http_cookie;

	#----------------------------------------------------------------------
	# HTTPリクエストの発行
	#----------------------------------------------------------------------
	my $res;
	if ($https) {
		eval { require Net::SSLeay };
		my ($page, $result, @headers);
		if ($method eq 'POST') {
			($page, $result, @headers) = Net::SSLeay::post_https($host, $port, $path, $header, $content);
		} else {
			($page, $result, @headers) = Net::SSLeay::get_https ($host, $port, $path, $header);
		}

		$self->parse_status_line($result, $host);

		$res = [ $result ];
		while(@headers) {
			my $name = shift(@headers);
			my $val  = shift(@headers);
			push(@$res, "$name: $val");
		}
		push(@$res, '');
		push(@$res, $page);
	} else {
		# HTTP/1.1は chunked 未実装のため非対応
		my $request = "$method $path HTTP/1.0\r\n$header\r\nConnection: close\r\n$content";
		$res = $self->get_data($host, $port, $request);
		if (ref($res) ne 'ARRAY') { return $res; }	# fail to return
	}

	#----------------------------------------------------------------------
	# ヘッダの解析
	#----------------------------------------------------------------------
	delete $self->{location};
	my $header= $self->{header} = [];
	while(@$res) {
		my $line = shift(@$res);
		$line =~ s/[\r\n]//g;		# 改行除去
		if ($line eq '') { last; }	# ヘッダの終わり
		push(@$header, $line);
		# Cookie
		if ($self->{use_cookie} && $line =~ /^set-cookie:\s*(.*)$/i) {
			my @cookie = split(/\s*;\s*/, $1);
			my %h;
			my $cookie_dom = $host;
			my ($name, $value) = split("=", shift(@cookie));
			$h{name}  = $name;
			$h{value} = $value;
			foreach(@cookie) {
				if ($_ !~ /(.*?)=(.*)/) { next; }
				$h{$1} = $2;
				if ($1 eq 'domain') {
					my $dom = $2;
					if ($dom =~ /\.?([\w\-]+\.[\w\-]+\.[\w\-]+)\.?/) {
						$cookie_dom = '.' . $1;
					}
				}
			}
			$cookie->{"$cookie_dom;$h{name}"} = \%h;	# cookie保存
		}
		# Redirect 
		if ($line =~ /^location:\s*(.*)$/i) {
			$self->{location} = $1;
		}
	}
	return $res;
}

###############################################################################
# ■サブルーチン
###############################################################################
#------------------------------------------------------------------------------
# ●タイムアウトの設定
#------------------------------------------------------------------------------
sub set_timeout {
	my ($self, $timeout) = @_;
	$self->{timeout} = $timeout+0 || 30;
}

#------------------------------------------------------------------------------
# ●USER-AGENTの設定
#------------------------------------------------------------------------------
sub set_agent {
	my $self = shift;
	$self->{http_agent} = shift || "Simple HTTP agent $VERSION";
}

###############################################################################
# ■エラー処理
###############################################################################
sub error_to_root {
	my $self = shift;
	$self->{error_to_root} = shift;
}

sub error {
	my $self   = shift;
	my $socket = shift;
	my $error  = shift;
	my $ROBJ   = $self->{ROBJ};
	if (defined $socket) { close($socket); }
	if (defined $ROBJ) {
		if ($self->{error_to_root}) { return $ROBJ->error($error, @_); }
		$error = $ROBJ->message_translate($error, @_);
	} elsif (@_) {
		$error = sprintf($error, @_);
	}
	$self->{error_msg} = $error;
	return undef;
}


sub encode_uricom {
	my $self = shift;
	foreach(@_) {
		$_ =~ s/([^\w!\(\)\*\-\.\~:])/'%' . unpack('H2',$1)/eg;
	}
	return $_[0];
}

1;

#!/usr/bin/env python3
# coding: utf-8

import datetime as dt
import http.client
import json
import logging
import os
import random
import sys

import flask
from flaskext import markdown as flask_markdown
import flask_babel

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from dancebooks.config import config
from dancebooks import bib_parser
from dancebooks import const
from dancebooks import db
from dancebooks import search
from dancebooks import markdown
from dancebooks import messenger
from dancebooks import utils
from dancebooks import utils_flask

items, item_index = bib_parser.BibParser().parse_folder(config.parser.bibdata_dir)

markdown_cache = markdown.MarkdownCache()

debug_mode = False


def get_locale():
	"""
	Extracts locale from request
	"""
	lang = (
		flask.request.cookies.get("lang", None) or
		getattr(flask.g, "lang", None) or
		flask.request.accept_languages.best_match(config.www.languages)
	)
	if lang in config.www.languages:
		return lang
	else:
		return utils.first(config.www.languages)


def init_apps():
	logging.info("Starting up")
	flask_app = flask.Flask(__name__)
	babel_app = flask_babel.Babel(flask_app, locale_selector=get_locale)
	return (flask_app, babel_app)


flask_app, babel_app = init_apps()
flask_app.config["BABEL_DEFAULT_LOCALE"] = utils.first(config.www.languages)
flask_app.config["USE_EVALEX"] = False
flask_markdown_app = flask_markdown.Markdown(flask_app)

flask_app.jinja_env.trim_blocks = True
flask_app.jinja_env.lstrip_blocks = True
flask_app.jinja_env.keep_trailing_newline = False

#filling jinja filters
flask_app.jinja_env.filters["author_link"] = utils_flask.make_author_link
flask_app.jinja_env.filters["keyword_link"] = utils_flask.make_keyword_link
flask_app.jinja_env.filters["as_set"] = utils_flask.as_set
flask_app.jinja_env.filters["translate_language"] = utils_flask.translate_language
flask_app.jinja_env.filters["translate_type"] = utils_flask.translate_type
flask_app.jinja_env.filters["translate_keyword_category"] = utils_flask.translate_keyword_cat
flask_app.jinja_env.filters["translate_keyword_ref"] = utils_flask.translate_keyword_ref
flask_app.jinja_env.filters["is_url_self_served"] = utils.is_url_self_served
flask_app.jinja_env.filters["format_date"] = utils_flask.format_date
flask_app.jinja_env.filters["format_pages"] = utils_flask.format_pages
flask_app.jinja_env.filters["format_number"] = utils_flask.format_number
flask_app.jinja_env.filters["format_catalogue_code"] = utils_flask.format_catalogue_code
flask_app.jinja_env.filters["format_item_id"] = utils_flask.format_item_id
flask_app.jinja_env.filters["format_transcription_url"] = utils_flask.format_transcription_url
flask_app.jinja_env.filters["format_guid_for_rss"] = utils_flask.format_guid_for_rss
flask_app.jinja_env.filters["format_transcribed_by"] = utils_flask.format_transcribed_by


def jinja_self_served_url_size(url, item):
	file_name, file_size = utils.get_file_info_from_url(url, item)
	return utils.pretty_print_file_size(file_size)

flask_app.jinja_env.filters["self_served_url_size"] = jinja_self_served_url_size

#filling jinja global variables
flask_app.jinja_env.globals["config"] = config
flask_app.jinja_env.globals["utils"] = utils


@flask_app.get("/secret-cookie")
@utils_flask.log_exceptions()
def secret_cookie():
	response = flask.make_response(flask.redirect("/"))
	response.set_cookie(
		config.www.secret_cookie_key,
		value=config.www.secret_cookie_value,
		max_age=const.SECONDS_IN_YEAR,
		httponly=True
	)
	return response


@flask_app.get("/ui-lang/<string:lang>")
@utils_flask.log_exceptions()
def choose_ui_lang(lang):
	next_url = flask.request.referrer or "/"
	if lang in config.www.languages:
		response = flask.make_response(flask.redirect(next_url))
		response.set_cookie(
			"lang",
			value=lang,
			max_age=const.SECONDS_IN_YEAR,
			httponly=True
		)
		return response
	else:
		flask.abort(http.client.NOT_FOUND, "Language isn't available")


@flask_app.get("/")
@utils_flask.log_exceptions()
@utils_flask.check_secret_cookie("show_secrets")
def root(show_secrets):
	return flask.render_template(
		"index.html",
		entry_count=len(items),
		show_secrets=(show_secrets or debug_mode)
	)


@flask_app.get("/search")
@flask_app.get("/basic-search")
@flask_app.get("/advanced-search")
@flask_app.get("/all-fields-search")
@utils_flask.check_secret_cookie("show_secrets")
@utils_flask.log_exceptions()
def search_items(show_secrets):
	request_args = {
		key: value.strip()
		for key, value
		in flask.request.values.items()
		if value and (key in config.www.search_params)
	}
	request_keys = set(request_args.keys())

	order_by = flask.request.values.get("orderBy", const.DEFAULT_ORDER_BY)
	if order_by not in config.www.order_by_keys:
		flask.abort(http.client.BAD_REQUEST, f"Key {order_by} is not supported for ordering")

	#if request_args is empty, we should render empty search form
	if len(request_args) == 0:
		flask.abort(http.client.BAD_REQUEST, "No search parameters specified")

	found_items = set(items)

	for index_to_use in (config.www.indexed_search_params & request_keys):

		value_to_use = request_args[index_to_use]

		if (
			(index_to_use in config.parser.list_params) or
			(index_to_use in config.parser.keyword_list_params)
		):
			values_to_use = utils.strip_split_list(value_to_use, ",")
		else:
			values_to_use = [value_to_use]

		for value in values_to_use:
			if index_to_use == "availability":
				value = bib_parser.Availability(value)
			indexed_items = set(item_index[index_to_use].get(value, set()))
			found_items &= indexed_items

	searches = []
	try:
		for search_key in (config.www.nonindexed_search_params & request_keys):
			# argument can be missing or be empty
			# both cases should be ignored during search
			search_param = request_args[search_key]

			if len(search_param) > 0:
				param_filter = search.search_for(search_key, search_param)
				if param_filter is not None:
					searches.append(param_filter)
	except Exception as ex:
		flask.abort(http.client.BAD_REQUEST, f"Some of the search parameters are wrong: {ex}")

	found_items = filter(search.and_(searches), found_items)
	if order_by == "year_from":
		key_func = lambda item: item.get("year_from")
	elif order_by == "source":
		key_func = lambda item: item.get("source")
	elif order_by == "added_on":
		key_func = lambda item: item.get("added_on")
	elif order_by == "author":
		key_func = lambda item: item.get("author") or []
	elif order_by == "location":
		key_func = lambda item: item.get("location") or []
	elif order_by == "series":
		key_func = lambda item: item.get("series") or ""
	elif order_by == "number":
		key_func = lambda item: item.get("number") or ""
	elif order_by == "serial_number":
		key_func = lambda item: item.get("serial_number") or ""

	found_items = list(sorted(found_items, key=key_func))



	format = flask.request.values.get("format", "html")
	if (format == "html"):
		return flask.render_template(
			"search.html",
			found_items=found_items,
			show_secrets=(show_secrets or debug_mode)
		)
	elif (format == "csv"):
		response = flask.make_response(utils.render_to_csv(found_items))
		response.headers["Content-Type"] = "text/csv"
		response.headers["Content-Disposition"] = "attachment;filename=search_results.csv"
		return response
	else:
		flask.abort(
			http.client.BAD_REQUEST,
			f"Unsupported output format {format}"
		)


@flask_app.get("/books/<string:book_id>")
@utils_flask.check_id_redirections("book_id")
@utils_flask.check_secret_cookie("show_secrets")
@utils_flask.log_exceptions()
def get_book(book_id, show_secrets):
	items = item_index["id"].get(book_id, None)
	if items is None:
		flask.abort(http.client.NOT_FOUND, f"Book with id {book_id} was not found")

	item = utils.first(items)
	captcha_key = random.choice(list(config.www.secret_questions.keys()))

	return flask.render_template(
		"book.html",
		item=item,
		show_secrets=(show_secrets or debug_mode),
		captcha_key=captcha_key
	)


@flask_app.get("/books/<string:book_id>/pdf/<int:index>")
@utils_flask.check_id_redirections("book_id")
@utils_flask.log_exceptions()
def get_book_pdf(book_id, index):
	"""
	TODO: I'm a huge method that isn't easy to read
	Please, refactor me ASAP
	"""
	utils_flask.require(index > 0, http.client.NOT_FOUND, "Param index should be positive number")

	items = item_index["id"].get(book_id, None)
	if items is None:
		flask.abort(http.client.NOT_FOUND, f"Book with id {book_id} was not found")
	item = utils.first(items)

	request_uri = flask.request.path
	item_urls = item.get("url") or set()
	filenames = item.get("filename")
	is_url_valid = (
		(request_uri in item_urls) and
		utils.is_url_local(request_uri) and
		utils.is_url_self_served(request_uri) and
		index <= len(filenames)
	)
	utils_flask.require(is_url_valid, http.client.NOT_FOUND, f"Book with id {book_id} is not available for download")

	filename = filenames[index - 1]
	pdf_full_path = os.path.join(config.www.elibrary_dir, filename)

	if not os.path.isfile(pdf_full_path):
		message = f"Item {book_id} metadata is wrong: file for {request_uri} is missing"
		logging.error(message)
		flask.abort(http.client.INTERNAL_SERVER_ERROR, message)

	logging.info(f"Sending pdf file: {pdf_full_path}")
	basename = os.path.basename(pdf_full_path)
	return flask.send_file(
		pdf_full_path,
		as_attachment=True,
		download_name=basename
	)


@flask_app.get("/books/<string:item_id>/transcription")
@utils_flask.check_id_redirections("item_id")
@utils_flask.log_exceptions()
def get_book_markdown(item_id):
	items = item_index["id"].get(item_id)
	if items is None:
		flask.abort(
			http.client.NOT_FOUND,
			f"Item with id {item_id} was not found"
		)

	item = utils.first(items)
	transcription = item.get("transcription")
	if transcription is None:
		flask.abort(
			http.client.NOT_FOUND,
			f"Transcription for item {item_id} is not available"
		)

	markdown_file = os.path.join(
		config.parser.markdown_dir,
		transcription
	)
	return flask.render_template(
		"markdown.html",
		markdown_data=markdown_cache.get(markdown_file),
		item=item
	)


@flask_app.post("/books/<string:book_id>")
@utils_flask.jsonify()
@utils_flask.log_exceptions()
@utils_flask.check_captcha()
def edit_book(book_id):
	items = item_index["id"].get(book_id, None)

	if items is None:
		flask.abort(http.client.NOT_FOUND, f"Book with id {id} was not found")

	message = utils_flask.extract_string_from_request("message")
	from_name = utils_flask.extract_string_from_request("name")
	from_email = utils_flask.extract_email_from_request("email")

	if not all([message, from_name, from_email]):
		flask.abort(http.client.BAD_REQUEST, "Empty values aren't allowed")

	item = utils.first(items)
	message = messenger.ErrorReport(item, from_email, from_name, message)
	message.send()

	return {"message": flask_babel.gettext("interface:report:thanks")}


@flask_app.post("/books/<string:book_id>/keywords")
@utils_flask.jsonify()
@utils_flask.log_exceptions()
@utils_flask.check_captcha()
def edit_book_keywords(book_id):
	items = item_index["id"].get(book_id, None)

	if items is None:
		flask.abort(http.client.NOT_FOUND, f"Book with id {id} was not found")

	suggested_keywords = utils_flask.extract_keywords_from_request("keywords")
	from_name = utils_flask.extract_string_from_request("name")
	from_email = utils_flask.extract_email_from_request("email")

	if not all([suggested_keywords, from_name, from_email]):
		flask.abort(http.client.BAD_REQUEST, "Empty values aren't allowed")

	item = utils.first(items)
	message = messenger.KeywordsSuggest(item, from_email, from_name, suggested_keywords)
	message.send()

	return {"message": flask_babel.gettext("interface:report:thanks")}


@flask_app.get("/options")
@utils_flask.jsonify()
@utils_flask.log_exceptions()
def get_options():
	options = dict()

	options["languages"] = [
		(langid, utils_flask.translate_language(langid))
		for langid in item_index["langid"].keys()
		if not langid.startswith("!")
	]

	options["keywords"] = [
		(
			category,
			{
				"translation": utils_flask.translate_keyword_cat(category),
				"keywords": category_keywords
			}
		)
		for category, category_keywords in config.parser.category_keywords.items()
	]

	options["types"] = [
		(type, utils_flask.translate_type(type))
		for type in sorted(item_index["type"].keys())
	]

	options["source_files"] = [
		(source_file, source_file)
		for source_file in sorted(item_index["source_file"].keys())
	]

	return options


@flask_app.get("/rss/books")
@utils_flask.log_exceptions()
def rss_redirect():
	lang = get_locale()
	return flask.redirect(f"/rss/{lang}/books")


@flask_app.get("/rss/<string:lang>/books")
@utils_flask.log_exceptions()
def get_books_rss(lang):
	if lang in config.www.languages:
		#setting attribute in flask.g so it cat be returned by get_locale call
		setattr(flask.g, "lang", lang)
	else:
		flask.abort(http.client.NOT_FOUND, "Language isn't available")

	response = flask.make_response(flask.render_template(
		"rss/books.xml",
		item_index={
			date: item
			for date, item in item_index["added_on"].items()
			if date < dt.datetime.now() - dt.timedelta(days=1)
		}
	))
	response.content_type = "application/rss+xml; charset=utf-8"
	return response


@flask_app.get("/backups")
@utils_flask.log_exceptions()
def get_backups():
	format = utils_flask.extract_string_from_request("format", default="html")
	with db.make_transaction() as session:
		backups = session.query(db.Backup).order_by(db.Backup.path).all()
	if format == "html":
		return flask.render_template("backups.html", backups=backups)
		pass
	elif format == "json":
		response = flask.make_response(json.dumps(backups, cls=db.SqlAlchemyEncoder))
		response.content_type = "application/json; charset=utf-8"
		return response
	else:
		flask.abort(http.client.BAD_REQUEST, f"Unknown format: {format}")


STATIC_TEMPLATES_DIR = os.path.join(os.path.dirname(__file__), "templates/static")
STATIC_FILES_DIR = os.path.join(os.path.dirname(__file__), "static")
@flask_app.get("/<path:filename>")
@utils_flask.log_exceptions()
def everything_else(filename):
	if filename.endswith("/"):
		filename += "index.html"

	if os.path.isfile(os.path.join(STATIC_TEMPLATES_DIR, filename)):
		return flask.render_template("static/" + filename)
	elif os.path.isfile(os.path.join(STATIC_FILES_DIR, filename)):
		return flask_app.send_static_file(filename)
	else:
		flask.abort(http.client.NOT_FOUND, flask.request.base_url)


@flask_app.get("/ping")
def ping():
	return "OK"


# Setting up some custom error handlers
for code in (
	http.client.BAD_REQUEST,
	http.client.FORBIDDEN,
	http.client.NOT_FOUND,
	http.client.INTERNAL_SERVER_ERROR
):
	flask_app.errorhandler(code)(utils_flask.http_exception_handler)

flask_app.errorhandler(Exception)(utils_flask.http_exception_handler)

if __name__ == "__main__":
	debug_mode = True
	flask_app.run(host="0.0.0.0")


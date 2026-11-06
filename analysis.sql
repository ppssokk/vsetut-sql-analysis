/* Проект «Разработка витрины и решение ad-hoc задач»
 * Цель проекта: подготовка витрины данных маркетплейса «ВсёТут»
 * и решение четырех ad hoc задач на её основе
 * 
 * Автор: Али Фирас
 * Дата: 19.08.2026
*/



/* Часть 1. Разработка витрины данных
 * Напишите ниже запрос для создания витрины данных
*/

WITH
	top_regions AS (
	    -- Топ-3 региона по количеству доставленных и отменённых заказов
	    SELECT
	        u.region
	    FROM ds_ecom.users AS u
	    JOIN ds_ecom.orders AS o
	        ON u.buyer_id = o.buyer_id
	    WHERE o.order_status IN ('Доставлено', 'Отменено')
	    GROUP BY u.region
	    ORDER BY COUNT(o.order_id) DESC, u.region
	    LIMIT 3),
	main AS (
	    -- Основной набор заказов: нужные статусы + топ-3 региона
	    SELECT
	        o.order_id,
	        u.user_id,
	        u.region,
	        o.order_status,
	        o.order_purchase_ts
	    FROM ds_ecom.users AS u
	    JOIN ds_ecom.orders AS o
	        ON u.buyer_id = o.buyer_id
	    WHERE o.order_status IN ('Доставлено', 'Отменено')
	      AND u.region IN (
	          SELECT region
	          FROM top_regions
	      )
	),
	reviews_by_order AS (
	    -- Средний рейтинг каждого заказа.
	    -- Исправляем шкалу 10–50 на шкалу 1–5
	    SELECT
	        order_id,
	        AVG(
	            CASE
	                WHEN review_score > 5
	                    THEN review_score / 10.0
	                ELSE review_score
	            END
	        ) AS review_score
	    FROM ds_ecom.order_reviews
	    GROUP BY order_id
	),
	items_by_order AS (
	    -- Полная стоимость каждого заказа: товары + доставка
	    SELECT
	        order_id,
	        SUM(price + delivery_cost) AS order_cost
	    FROM ds_ecom.order_items
	    GROUP BY order_id
	),
	payments_by_order AS (
	    -- Платёжные признаки на уровне одного заказа
	    SELECT
	        order_id,
	        BOOL_OR(payment_installments > 1) AS is_installment,
	        BOOL_OR(payment_type = 'промокод') AS has_promo,
	        (
	            ARRAY_AGG(
	                payment_type
	                ORDER BY payment_sequential
	            )
	        )[1] AS first_payment_type
	    FROM ds_ecom.order_payments
	    GROUP BY order_id
	),
	basic_user_info AS (
	    -- Основная информация о клиенте в конкретном регионе
	    SELECT
	        user_id,
	        region,
	        MIN(order_purchase_ts) AS first_order_ts,
	        MAX(order_purchase_ts) AS last_order_ts,
	        MAX(order_purchase_ts) - MIN(order_purchase_ts) AS lifetime
	    FROM main
	    GROUP BY user_id, region
	),
	orders_by_user AS (
	    -- Статистика по заказам и рейтингам
	    SELECT
	        m.user_id,
	        m.region,
	        COUNT(m.order_id) AS total_orders,
	        AVG(r.review_score) AS avg_order_rating,
	        COUNT(m.order_id) FILTER (WHERE r.review_score IS NOT NULL) AS num_orders_with_rating,
	        COUNT(m.order_id) FILTER (WHERE m.order_status = 'Отменено') AS num_canceled_orders,
	        COUNT(m.order_id) FILTER (WHERE m.order_status = 'Отменено')::NUMERIC / NULLIF(COUNT(m.order_id), 0) AS canceled_orders_ratio,
	        BOOL_OR(m.order_status = 'Отменено')::int AS used_cancel
	    FROM main AS m
	    LEFT JOIN reviews_by_order AS r
	        ON m.order_id = r.order_id
	    GROUP BY m.user_id, m.region
	),
	costs_by_user AS (
	    -- Стоимость только доставленных заказов
	    SELECT
	        m.user_id,
	        m.region,
	        SUM(i.order_cost) FILTER (WHERE m.order_status = 'Доставлено') AS total_order_costs,
	        AVG(i.order_cost) FILTER (WHERE m.order_status = 'Доставлено') AS avg_order_cost
	    FROM main AS m
	    LEFT JOIN items_by_order AS i
	        ON m.order_id = i.order_id
	    GROUP BY m.user_id, m.region
	),
	payment_info AS (
	    -- Платёжные характеристики клиента
	    SELECT
	        m.user_id,
	        m.region,
	        COUNT(m.order_id) FILTER (WHERE p.is_installment) AS num_installment_orders,
	        COUNT(m.order_id) FILTER (WHERE p.has_promo) AS num_orders_with_promo,
			COALESCE(BOOL_OR(p.first_payment_type = 'денежный перевод'), FALSE)::int AS used_money_transfer,
	        COALESCE(BOOL_OR(p.is_installment), FALSE)::int AS used_installments
	    FROM main AS m
	    LEFT JOIN payments_by_order AS p
	        ON m.order_id = p.order_id
	    GROUP BY m.user_id, m.region
	)
SELECT
    b.user_id,
    b.region,
    b.first_order_ts,
    b.last_order_ts,
    b.lifetime,
    o.total_orders,
    o.avg_order_rating,
    o.num_orders_with_rating,
    o.num_canceled_orders,
    o.canceled_orders_ratio,
    c.total_order_costs,
    c.avg_order_cost,
    p.num_installment_orders,
    p.num_orders_with_promo,
    p.used_money_transfer,
    p.used_installments,
    o.used_cancel
FROM basic_user_info AS b
LEFT JOIN orders_by_user AS o
    USING (user_id, region)
LEFT JOIN costs_by_user AS c
    USING (user_id, region)
LEFT JOIN payment_info AS p
    USING (user_id, region);



/* Часть 2. Решение ad hoc задач
 * Для каждой задачи напишите отдельный запрос.
 * После каждой задачи оставьте краткий комментарий с выводами по полученным результатам.
*/
/* Задача 1. Сегментация пользователей 
 * Разделите пользователей на группы по количеству совершённых ими заказов.
 * Подсчитайте для каждой группы общее количество пользователей,
 * среднее количество заказов, среднюю стоимость заказа.
 * 
 * Выделите такие сегменты:
 * - 1 заказ — сегмент 1 заказ
 * - от 2 до 5 заказов — сегмент 2-5 заказов
 * - от 6 до 10 заказов — сегмент 6-10 заказов
 * - 11 и более заказов — сегмент 11 и более заказов
*/

-- Напишите ваш запрос тут
WITH segments AS (
    SELECT
        user_id,
        total_orders,
        total_order_costs,
        CASE
            WHEN total_orders = 1 THEN '1. 1 заказ'
            WHEN total_orders BETWEEN 2 AND 5 THEN '2. от 2 до 5 заказов'
            WHEN total_orders BETWEEN 6 AND 10 THEN '3. от 6 до 10 заказов'
            WHEN total_orders >= 11 THEN '4. 11 и более заказов'
        END AS segment
    FROM ds_ecom.product_user_features
)
SELECT
    segment,
    COUNT(DISTINCT s.user_id) AS number_of_users,
    round(AVG(total_orders), 2) AS avg_of_orders,
    round(SUM(total_order_costs) / SUM(total_orders), 2) AS avg_order_cost
FROM segments s
GROUP BY segment
ORDER BY segment;
/* Напишите краткий комментарий с выводами по результатам задачи 1.
 Судя по полученным данным, подавляющее большинство клиентов совершили только один заказ за рассматриваемый период.
 Пользователей с повторными заказами значительно меньше, что может указывать на низкую долю повторных покупок.
 Средний чек в двух крупнейших сегментах составляет около 3000 руб. Сегменты 3 и 4 содержат только 6 пользователй, 
 поэтому делать выводы по их среднему чеку некорректно.
*/

/* Задача 2. Ранжирование пользователей 
 * Отсортируйте пользователей, сделавших 3 заказа и более, по убыванию среднего чека покупки.  
 * Выведите 15 пользователей с самым большим средним чеком среди указанной группы.
*/

SELECT 
	dense_rank() OVER (ORDER BY puf.avg_order_cost DESC),
	*
FROM ds_ecom.product_user_features puf 
WHERE puf.total_orders >= 3
ORDER BY puf.avg_order_cost DESC
LIMIT 15;

-- Напишите ваш запрос тут

/* Напишите краткий комментарий с выводами по результатам задачи 2.
 * Среди 15 пользователей с наибольшим средним чеком его значение составляет примерно от 5500 до 14700 рублей.
 * Большинство этих клиентов совершили по 3 заказа, поэтому высокий средний чек не сопровождается высокой частотой покупок.
 * Отменённых заказов среди данной группы нет. 
 * При этом рассрочка используется достаточно активно, а применение промокодов встречается редко.
*/



/* Задача 3. Статистика по регионам. 
 * Для каждого региона подсчитайте:
 * - общее число клиентов и заказов;
 * - среднюю стоимость одного заказа;
 * - долю заказов, которые были куплены в рассрочку;
 * - долю заказов, которые были куплены с использованием промокодов;
 * - долю пользователей, совершивших отмену заказа хотя бы один раз.
*/

-- Напишите ваш запрос тут
SELECT
	puf.region,
	count(*) AS number_of_users,
	sum(puf.total_orders) AS number_of_orders,
	round(avg(puf.avg_order_cost), 2) AS avg_order_cost,
	round(sum(puf.num_installment_orders)::numeric(10, 2) / sum(puf.total_orders) * 100, 2) || '%' AS ratio_of_installment,
	round(sum(puf.num_orders_with_promo)::numeric(10, 2) / sum(puf.total_orders) * 100, 2) || '%' AS ratio_of_promo,
	round(avg(puf.used_cancel) * 100, 2) || '%' AS ratio_used_cancel
FROM ds_ecom.product_user_features puf
GROUP BY puf.region
ORDER BY count(*);
 
/* Напишите краткий комментарий с выводами по результатам задачи 3.
 * Москва значительно лидирует по объёму: 39400 клиентов и 40700 заказов. 
 * При этом самый высокий средний чек наблюдается в Санкт-Петербурге — около 3620 рублей, 
 * а самый низкий в Москве — около 3170 руб. Рассрочка наиболее активно используется в 
 * Санкт-Петербурге и Новосибирской области — примерно в 55% заказов, 
 * в Москве — около 48%. Промокоды во всех регионах используются редко, их доля составляет всего 3,7–4,2%. 
 * Доля клиентов, которые хотя бы раз отменяли заказ, 
 * во всех регионах меньше 1%, максимальное значение наблюдается в Москве — около 0,63%.

*/



/* Задача 4. Активность пользователей по первому месяцу заказа в 2023 году
 * Разбейте пользователей на группы в зависимости от того, в какой месяц 2023 года они совершили первый заказ.
 * Для каждой группы посчитайте:
 * - общее количество клиентов, число заказов и среднюю стоимость одного заказа;
 * - средний рейтинг заказа;
 * - долю пользователей, использующих денежные переводы при оплате;
 * - среднюю продолжительность активности пользователя.
*/

-- Напишите ваш запрос тут
set lc_time = 'ru_RU';

WITH month_table AS (
	SELECT
		*,
		TO_CHAR(first_order_ts, 'TMmon') AS group_month
	FROM ds_ecom.product_user_features puf
	WHERE puf.first_order_ts >= '2023-01-01'::timestamp AND puf.first_order_ts < '2024-01-01'::timestamp
	)
SELECT
	group_month,
	count(*) AS number_of_users,
	sum(total_orders) AS number_of_orders,
	avg(avg_order_cost)::numeric(10, 2) AS avg_order_cost,
	avg(avg_order_rating)::numeric(10, 2) AS avg_order_rating,
	((sum(used_money_transfer)::numeric / count(*)) * 100)::numeric(10, 2) || '%' AS ratio_used_money_transfer,
	avg(lifetime)::interval(0) AS avg_lifetime
FROM month_table
GROUP BY group_month
ORDER BY EXTRACT(MONTH FROM MIN(first_order_ts)); 
/* Напишите краткий комментарий с выводами по результатам задачи 4.
 * В 2023 году количество новых пользователей в целом увеличивалось к концу года: минимальное значение наблюдается в январе, а максимальное — в ноябре. 
 * Количество заказов во всех группах лишь немного превышает количество пользователей, что говорит о невысокой повторной активности клиентов.
 * Средний чек в зависимости от месяца первого заказа составляет примерно 2,6–3,3 тыс. руб., при этом выраженной устойчивой зависимости от месяца не наблюдается. 
 * Средний рейтинг заказов во всех группах остаётся достаточно высоким и находится примерно на уровне 4,0–4,3. Доля пользователей, использовавших денежный перевод,
 * стабильна и составляет около 19–22%. Средняя продолжительность активности выше у пользователей, совершивших первый заказ в начале года, 
 * и снижается для более поздних когорт, что в том числе связано с меньшим доступным периодом наблюдения за такими пользователями.
*/

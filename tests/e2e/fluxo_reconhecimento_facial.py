"""Teste ponta a ponta do reconhecimento facial no balcão (câmera simulada com vídeos .y4m).

Uso: E2E_CAM=<pasta com pessoaA.y4m, pessoaB.y4m, A.png, B.png> python3 tests/e2e/fluxo_reconhecimento_facial.py
pessoaA = rosto cadastrado (DEMO-1001) virando a cabeça; pessoaB = rosto não cadastrado.
"""
import os
import re
import shutil
import tempfile
import time
from playwright.sync_api import sync_playwright, expect

BASE = os.environ.get('E2E_BASE', 'http://localhost:5173')
OUT = os.environ.get('E2E_OUT', 'tests/e2e/capturas')
CAM = os.environ['E2E_CAM']
os.makedirs(OUT, exist_ok=True)


def login(page, email):
    page.goto(f'{BASE}/login')
    page.get_by_label('E-mail').fill(email)
    page.get_by_label('Senha').fill('teste123')
    page.get_by_role('button', name='Entrar').click()


def cam_browser(p, video):
    return p.chromium.launch(args=['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', f'--use-file-for-fake-video-capture={video}'])


# Base de fotos no formato da empresa: Fotos/<CPF>/<1..5>/<arquivo>
base = tempfile.mkdtemp()
fotos = os.path.join(base, 'Fotos')
for cpf, img, n in [('00201955407', 'A.png', 2), ('00999999999', 'B.png', 1)]:
    for i in range(1, n + 1):
        os.makedirs(os.path.join(fotos, cpf, str(i)), exist_ok=True)
        shutil.copy(os.path.join(CAM, img), os.path.join(fotos, cpf, str(i), f'0f2201e5-27a5-4b41-a9f3-{i}.png'))
planilha = os.path.join(base, 'funcionarios.csv')
with open(planilha, 'w', encoding='utf-8') as f:
    f.write('Nome;Matrícula;Função;CPF\nJosé Carlos da Silva;DEMO-1001;Mecânico;201.955.407\n')

with sync_playwright() as p:
    plain = p.chromium.launch()
    actx = plain.new_context(viewport={'width': 1366, 'height': 1000})
    a = actx.new_page()

    # ---------------- Administrador: liga e importa a base de fotos
    login(a, 'admin@teste.local')
    a.wait_for_url(re.compile(r'.*/$'))
    a.get_by_role('link', name='Reconhecimento facial').click()
    expect(a.get_by_text(re.compile('de \\d+ funcionários ativos com rosto'))).to_be_visible(timeout=15000)
    a.get_by_label('Reconhecimento facial ligado no balcão').check()
    a.get_by_role('button', name='Salvar').click()
    expect(a.get_by_text('Configuração salva.')).to_be_visible(timeout=10000)
    a.get_by_test_id('face-folder').set_input_files(fotos)
    expect(a.get_by_text('2 pessoa(s) encontradas')).to_be_visible(timeout=10000)
    a.get_by_test_id('face-sheet').set_input_files(planilha)
    expect(a.get_by_text(re.compile('colunas “CPF” e “Matrícula”, 1 linha'))).to_be_visible(timeout=10000)
    expect(a.get_by_text(re.compile(r'1 CPF\(s\) da pasta não estão na planilha \(\*\*\*\.\*\*\*\.999-99\)'))).to_be_visible()
    a.get_by_role('button', name='Ler as fotos e cadastrar').click()
    expect(a.get_by_text(re.compile(r'1 funcionário\(s\) cadastrados \(2 leituras\)'))).to_be_visible(timeout=120000)
    expect(a.locator('table').get_by_text('José Carlos da Silva')).to_be_visible()
    a.screenshot(path=f'{OUT}/rf01_cadastro.png', full_page=True)
    actx.close()

    # Almoxarife fica na tela do balcão
    actx = plain.new_context(viewport={'width': 1366, 'height': 1000})
    a = actx.new_page()
    login(a, 'almox.mur@teste.local')
    a.wait_for_url(re.compile(r'.*/$'))
    a.goto(f'{BASE}/balcao')
    expect(a.get_by_text('Nova separação no balcão')).to_be_visible(timeout=15000)

    # ---------------- Pessoa não cadastrada: não reconhecida, chama o almoxarife
    bb = cam_browser(p, os.path.join(CAM, 'pessoaB.y4m'))
    tb = bb.new_context(viewport={'width': 1024, 'height': 900}, permissions=['camera']).new_page()
    login(tb, 'tablet.mur@teste.local')
    tb.wait_for_url(re.compile(r'.*/terminal$'))
    tb.get_by_role('button', name='RETIRAR PEÇAS').click(timeout=15000)
    expect(tb.get_by_text(re.compile('Não reconheci o seu rosto|Não tive certeza'))).to_be_visible(timeout=90000)
    tb.screenshot(path=f'{OUT}/rf02_nao_reconhecido.png', full_page=True)
    tb.get_by_role('button', name='Chamar o almoxarife').click()
    expect(tb.get_by_text('O almoxarife foi avisado')).to_be_visible(timeout=10000)
    expect(a.get_by_text('Solicitante não reconhecido')).to_be_visible(timeout=15000)
    a.get_by_role('button', name='Dispensar').click()
    expect(tb.get_by_role('button', name='RETIRAR PEÇAS')).to_be_visible(timeout=15000)
    bb.close()

    # ---------------- Pessoa cadastrada: reconhecida no tablet, ME aberta, confirmação pelo rosto
    ba = cam_browser(p, os.path.join(CAM, 'pessoaA.y4m'))
    t = ba.new_context(viewport={'width': 1024, 'height': 900}, permissions=['camera']).new_page()
    login(t, 'tablet.mur@teste.local')
    t.wait_for_url(re.compile(r'.*/terminal$'))
    t.wait_for_timeout(int(os.environ.get('E2E_IDLE_MS', '8000')))  # tablet parado no balcão (tempo para preparar)
    t0 = time.time()
    t.get_by_role('button', name='RETIRAR PEÇAS').click(timeout=15000)
    if not os.environ.get('E2E_OLD'):
        expect(t.get_by_test_id('face-ring')).to_be_visible(timeout=30000)
        t.screenshot(path=f'{OUT}/rf03a_circulo.png')
    t_ring = time.time() - t0
    expect(t.get_by_text('Olá, José!')).to_be_visible(timeout=90000)
    t_ident = time.time() - t0
    t.screenshot(path=f'{OUT}/rf03_reconhecido.png', full_page=True)

    expect(a.get_by_text('No balcão agora')).to_be_visible(timeout=15000)
    expect(a.get_by_text(re.compile('matrícula DEMO-1001 · reconhecido pelo rosto'))).to_be_visible()
    a.screenshot(path=f'{OUT}/rf04_almox_ve.png', full_page=True)
    # sem clicar em nada: o formulário já vem com o solicitante reconhecido
    expect(a.get_by_text('Atendendo · preencha abaixo')).to_be_visible(timeout=10000)
    expect(a.get_by_text('Atendendo José Carlos da Silva, reconhecido pelo rosto')).to_be_visible()
    a.get_by_label('Setor').select_option(label='Manutenção mecânica')
    expect(a.get_by_label('Tablet do solicitante')).to_be_disabled()
    a.get_by_role('button', name='Abrir separação').click()
    a.wait_for_url(re.compile(r'.*/balcao/[0-9a-f-]{36}$'))
    expect(t.get_by_text('Aguardando o almoxarife bipar os materiais')).to_be_visible(timeout=15000)

    a.locator('#balcao-leitura').click()
    a.keyboard.type('MAT-DEMO000001', delay=8)
    a.keyboard.press('Enter')
    expect(a.get_by_text('Material incluído')).to_be_visible(timeout=10000)
    a.get_by_role('button', name='FINALIZAR SEPARAÇÃO').click()
    a.get_by_role('button', name='Finalizar', exact=True).click()

    t.get_by_role('button', name='CONFIRMAR ME').click(timeout=15000)
    t.get_by_role('button', name='Está correto, confirmar').click()
    t1 = time.time()
    expect(t.get_by_text('Confirme a retirada com o seu rosto')).to_be_visible(timeout=10000)
    expect(t.get_by_text('ME confirmada').first).to_be_visible(timeout=90000)
    t_conf = time.time() - t1
    t.screenshot(path=f'{OUT}/rf05_confirmada.png', full_page=True)
    t2 = time.time()
    expect(t.get_by_role('button', name=re.compile(r'Próximo solicitante \(\d s\)'))).to_be_visible(timeout=5000)
    expect(t.get_by_role('button', name='RETIRAR PEÇAS')).to_be_visible(timeout=9000)
    t_volta = time.time() - t2

    expect(a.get_by_text(re.compile('ME confirmada pelo solicitante em'))).to_be_visible(timeout=15000)
    a.get_by_role('link', name='Ver detalhes da ME').click()
    expect(a.get_by_text('Identificação do solicitante')).to_be_visible(timeout=15000)
    expect(a.get_by_text(re.compile(r'Reconhecido pelo rosto no tablet \(semelhança \d+%\)'))).to_be_visible()
    expect(a.get_by_text(re.compile(r'Pelo rosto \(semelhança \d+%\)'))).to_be_visible()
    expect(a.get_by_text('Sem assinatura registrada.')).to_be_visible()
    a.screenshot(path=f'{OUT}/rf06_detalhe.png', full_page=True)
    ba.close()
    plain.close()
    print(f'TEMPOS: circulo no rosto {t_ring:.1f}s · identificado {t_ident:.1f}s · confirmacao {t_conf:.1f}s · volta para Retirar peças {t_volta:.1f}s')
    print('OK')
